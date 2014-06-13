module Shoulda # :nodoc:
  module Matchers
    module ActiveModel # :nodoc:
      # Ensures that the model is invalid if the given attribute is not unique.
      # It uses the first existing record or creates a new one if no record
      # exists in the database. It simply uses `validate: false` to get
      # around validations, so it will probably fail if there are `NOT NULL`
      # constraints. In that case, you must create a record before calling
      # `validate_uniqueness_of`.
      #
      # Example:
      #   it { should validate_uniqueness_of(:email) }
      #
      # Options:
      #
      # * <tt>with_message</tt> - value the test expects to find in
      #   <tt>errors.on(:attribute)</tt>. <tt>Regexp</tt> or <tt>String</tt>.
      #   Defaults to the translation for <tt>:taken</tt>.
      # * <tt>scoped_to</tt> - field(s) to scope the uniqueness to.
      # * <tt>case_insensitive</tt> - ensures that the validation does not
      #   check case. Off by default. Ignored by non-text attributes.
      # * <tt>allow_nil</tt> - ensures that the validation allows multiple nil
      #   values
      # * <tt>allow_blank</tt> - ensures that the validation allows multiple
      #   blank values
      #
      # Examples:
      #   it { should validate_uniqueness_of(:keyword) }
      #   it { should validate_uniqueness_of(:keyword).with_message(/dup/) }
      #   it { should validate_uniqueness_of(:email).scoped_to(:name) }
      #   it { should validate_uniqueness_of(:email).
      #                 scoped_to(:first_name, :last_name) }
      #   it { should validate_uniqueness_of(:keyword).case_insensitive }
      #   it { should validate_uniqueness_of(:keyword).allow_nil }
      #   it { should validate_uniqueness_of(:keyword).allow_blank }
      #
      def validate_uniqueness_of(attr)
        ValidateUniquenessOfMatcher.new(attr)
      end

      class ValidateUniquenessOfMatcher < ValidationMatcher # :nodoc:
        include Helpers

        def initialize(attribute)
          super(attribute)
          @options = {}
        end

        def scoped_to(*scopes)
          @options[:scopes] = [*scopes].flatten
          self
        end

        def with_message(message)
          @expected_message = message
          self
        end

        def case_insensitive
          @options[:case_insensitive] = true
          self
        end

        def allow_nil
          @options[:allow_nil] = true
          self
        end

        def allow_blank
          @options[:allow_blank] = true
          self
        end

        def description
          result = "require "
          result << "case sensitive " unless @options[:case_insensitive]
          result << "unique value for #{@attribute}"
          result << " scoped to #{@options[:scopes].join(', ')}" if @options[:scopes].present?
          result
        end

        def matches?(subject)
          @subject = subject.class.new
          @expected_message ||= :taken
          set_scoped_attributes &&
            validate_everything_except_duplicate_nils_or_blanks? &&
            validate_after_scope_change? &&
            allows_nil? &&
            allows_blank?
        end

        private

        def allows_nil?
          if @options[:allow_nil]
            ensure_nil_record_in_database
            allows_value_of(nil, @expected_message)
          else
            true
          end
        end

        def allows_blank?
          if @options[:allow_blank]
            ensure_blank_record_in_database
            allows_value_of('', @expected_message)
          else
            true
          end
        end

        def existing_record
          @existing_record ||= first_instance
        end

        def first_instance
          @subject.class.first || create_record_in_database
        end

        def ensure_nil_record_in_database
          unless existing_record_is_nil?
            create_record_in_database(nil_value: true)
          end
        end

        def ensure_blank_record_in_database
          unless existing_record_is_blank?
            create_record_in_database(blank_value: true)
          end
        end

        def existing_record_is_nil?
          @existing_record.present? && existing_value.nil?
        end

        def existing_record_is_blank?
          @existing_record.present? && existing_value.strip == ''
        end

        def create_record_in_database(options = {})
          @subject.class.new.tap do |instance|
            instance.__send__("#{@attribute}=", value_for_new_record(options))
            if has_secure_password?
              instance.password = 'password'
              instance.password_confirmation = 'password'
            end
            instance.save(validate: false)
          end
        end

        def value_for_new_record(options = {})
          case
          when options[:nil_value] then nil
          when options[:blank_value] then ''
          else 'a'
          end
        end

        def has_secure_password?
          @subject.class.ancestors.map(&:to_s).include?('ActiveModel::SecurePassword::InstanceMethodsOnActivation')
        end

        def set_scoped_attributes
          if @options[:scopes].present?
            @options[:scopes].all? do |scope|
              setter = :"#{scope}="
              if @subject.respond_to?(setter)
                @subject.__send__(setter, existing_record.__send__(scope))
                true
              else
                @failure_message = "#{class_name} doesn't seem to have a #{scope} attribute."
                false
              end
            end
          else
            true
          end
        end

        def validate_everything_except_duplicate_nils_or_blanks?
          if (@options[:allow_nil] && existing_value.nil?) ||
             (@options[:allow_blank] && existing_value.blank?)
            create_record_with_value
          end

          disallows_value_of(existing_value, @expected_message)
        end

        def create_record_with_value
          @existing_record = create_record_in_database
        end

        def validate_after_scope_change?
          if @options[:scopes].blank?
            true
          else
            all_records = @subject.class.all
            @options[:scopes].all? do |scope|
              previous_value = all_records.map(&scope).max

              # Assume the scope is a foreign key if the field is nil
              previous_value ||= correct_type_for_column(@subject.class.columns_hash[scope.to_s])

              next_value =
                if @subject.class.respond_to?(:defined_enums) && @subject.defined_enums[scope.to_s]
                  available_values = @subject.defined_enums[scope.to_s].reject do |key, _|
                    key == previous_value
                  end
                  available_values.keys.last
                elsif previous_value.respond_to?(:next)
                  previous_value.next
                elsif previous_value.respond_to?(:to_datetime)
                  previous_value.to_datetime.next
                else
                  previous_value.to_s.next
                end

              @subject.__send__("#{scope}=", next_value)

              if allows_value_of(existing_value, @expected_message)
                @subject.__send__("#{scope}=", previous_value)

                @failure_message_when_negated <<
                  " (with different value of #{scope})"
                true
              else
                @failure_message << " (with different value of #{scope})"
                false
              end
            end
          end
        end

        def correct_type_for_column(column)
          if column.type == :string
            '0'
          elsif column.type == :datetime
            DateTime.now
          elsif column.type == :uuid
            SecureRandom.uuid
          else
            0
          end
        end

        def class_name
          @subject.class.name
        end

        def existing_value
          value = existing_record.__send__(@attribute)
          if @options[:case_insensitive] && value.respond_to?(:swapcase!)
            value.swapcase!
          end
          value
        end
      end
    end
  end
end
