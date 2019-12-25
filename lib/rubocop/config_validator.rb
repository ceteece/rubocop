# frozen_string_literal: true

require 'pathname'

module RuboCop
  # Handles validation of configuration, for example cop names, parameter
  # names, and Ruby versions.
  class ConfigValidator
    extend Forwardable

    COMMON_PARAMS = %w[Exclude Include Severity inherit_mode
                       AutoCorrect StyleGuide Details].freeze
    INTERNAL_PARAMS = %w[Description StyleGuide
                         VersionAdded VersionChanged VersionRemoved
                         Reference Safe SafeAutoCorrect].freeze

    def_delegators :@config, :smart_loaded_path, :for_all_cops

    def initialize(config)
      @config = config
      @config_obsoletion = ConfigObsoletion.new(config)
      @target_ruby = TargetRuby.new(config)
    end

    def validate
      check_cop_config_value(@config)

      # Don't validate RuboCop's own files further. Avoids infinite recursion.
      return if @config.internal?

      valid_cop_names, invalid_cop_names = @config.keys.partition do |key|
        ConfigLoader.default_configuration.key?(key)
      end

      @config_obsoletion.reject_obsolete_cops_and_parameters

      alert_about_unrecognized_cops(invalid_cop_names)
      check_target_ruby
      validate_parameter_names(valid_cop_names)
      validate_enforced_styles(valid_cop_names)
      validate_syntax_cop
      reject_mutually_exclusive_defaults
    end

    def target_ruby_version
      target_ruby.version
    end

    def validate_section_presence(name)
      return unless @config.key?(name) && @config[name].nil?

      raise ValidationError,
            "empty section #{name} found in #{smart_loaded_path}"
    end

    private

    attr_reader :target_ruby

    def check_target_ruby
      return if target_ruby.supported?

      source = target_ruby.source
      last_version = target_ruby.rubocop_version_with_support

      msg = if last_version
              "RuboCop found unsupported Ruby version #{target_ruby_version} " \
              "in #{source}. #{target_ruby_version}-compatible " \
              "analysis was dropped after version #{last_version}."
            else
              'RuboCop found unknown Ruby version ' \
              "#{target_ruby_version.inspect} in #{source}."
            end

      msg += "\nSupported versions: #{TargetRuby.supported_versions.join(', ')}"

      raise ValidationError, msg
    end

    def alert_about_unrecognized_cops(invalid_cop_names)
      unknown_cops = []
      invalid_cop_names.each do |name|
        # There could be a custom cop with this name. If so, don't warn
        next if Cop::Cop.registry.contains_cop_matching?([name])

        # Special case for inherit_mode, which is a directive that we keep in
        # the configuration (even though it's not a cop), because it's easier
        # to do so than to pass the value around to various methods.
        next if name == 'inherit_mode'

        unknown_cops << "unrecognized cop #{name} found in " \
          "#{smart_loaded_path}"
      end
      raise ValidationError, unknown_cops.join(', ') if unknown_cops.any?
    end

    def validate_syntax_cop
      syntax_config = @config['Lint/Syntax']
      default_config = ConfigLoader.default_configuration['Lint/Syntax']

      return unless syntax_config &&
                    default_config.merge(syntax_config) != default_config

      raise ValidationError,
            "configuration for Syntax cop found in #{smart_loaded_path}\n" \
            'It\'s not possible to disable this cop.'
    end

    def validate_parameter_names(valid_cop_names)
      valid_cop_names.each do |name|
        validate_section_presence(name)
        each_invalid_parameter(name) do |param, supported_params|
          warn Rainbow(<<~MESSAGE).yellow
            Warning: #{name} does not support #{param} parameter.

            Supported parameters are:

              - #{supported_params.join("\n  - ")}
          MESSAGE
        end
      end
    end

    def each_invalid_parameter(cop_name)
      default_config = ConfigLoader.default_configuration[cop_name]

      @config[cop_name].each_key do |param|
        next if COMMON_PARAMS.include?(param) || default_config.key?(param)

        supported_params = default_config.keys - INTERNAL_PARAMS

        yield param, supported_params
      end
    end

    def validate_enforced_styles(valid_cop_names)
      valid_cop_names.each do |name|
        styles = @config[name].select { |key, _| key.start_with?('Enforced') }

        styles.each do |style_name, style|
          supported_key = RuboCop::Cop::Util.to_supported_styles(style_name)
          valid = ConfigLoader.default_configuration[name][supported_key]

          next unless valid
          next if valid.include?(style)
          next if validate_support_and_has_list(name, style, valid)

          msg = "invalid #{style_name} '#{style}' for #{name} found in " \
            "#{smart_loaded_path}\n" \
            "Valid choices are: #{valid.join(', ')}"
          raise ValidationError, msg
        end
      end
    end

    def validate_support_and_has_list(name, formats, valid)
      ConfigLoader.default_configuration[name]['AllowMultipleStyles'] &&
        formats.is_a?(Array) &&
        formats.all? { |format| valid.include?(format) }
    end

    def reject_mutually_exclusive_defaults
      disabled_by_default = for_all_cops['DisabledByDefault']
      enabled_by_default = for_all_cops['EnabledByDefault']
      return unless disabled_by_default && enabled_by_default

      msg = 'Cops cannot be both enabled by default and disabled by default'
      raise ValidationError, msg
    end

    def check_cop_config_value(hash, parent = nil)
      hash.each do |key, value|
        check_cop_config_value(value, key) if value.is_a?(Hash)

        next unless %w[Enabled
                       Safe
                       SafeAutoCorrect
                       AutoCorrect].include?(key) && value.is_a?(String)

        next if key == 'Enabled' && value == 'pending'

        raise ValidationError, msg_not_boolean(parent, key, value)
      end
    end

    # FIXME: Handling colors in exception messages like this is ugly.
    def msg_not_boolean(parent, key, value)
      "#{Rainbow('').reset}" \
        "Property #{Rainbow(key).yellow} of cop #{Rainbow(parent).yellow}" \
        " is supposed to be a boolean and #{Rainbow(value).yellow} is not."
    end
  end
end
