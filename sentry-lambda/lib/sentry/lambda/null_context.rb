module Sentry
  module Lambda
    # This class exists to allow nil to quack like an AWS context object, primarily for the purpose of supporting
    # automated tests which don't supply a context object.
    class NullContext
      def get_remaining_time_in_millis
        0
      end

      def function_name
        'n/a'
      end

      def function_version
        'n/a'
      end

      def invoked_function_arn
        'n/a'
      end

      def aws_request_id
        'n/a'
      end
    end
  end
end
