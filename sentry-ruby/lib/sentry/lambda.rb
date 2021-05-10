require 'sentry/lambda/capture_exceptions'

module Sentry
  module Lambda
    def self.wrap_handler(event:, context:, catpure_timeout_warning: false)
      CaptureExceptions.new(
        aws_event: event,
        aws_context: context,
        catpure_timeout_warning: catpure_timeout_warning
      ).call do
        yield
      end
    end
  end
end
