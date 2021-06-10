require "sentry-ruby"
require "sentry/integrable"
require "sentry/lambda/capture_exceptions"
require "sentry/lambda/null_context"

module Sentry
  module Lambda
    extend Integrable
    register_integration name: 'lambda', version: Sentry::Lambda::VERSION

    def self.wrap_handler(event:, context: NullContext.new, capture_timeout_warning: false)
      CaptureExceptions.new(
        aws_event: event,
        aws_context: context || NullContext.new,
        capture_timeout_warning: capture_timeout_warning
      ).call do
        yield
      end
    end
  end
end
