require 'sentry/lambda/capture_exceptions'

module Sentry
  module Lambda
    def self.capture_exceptions(event, context)
      CaptureExceptions.new(event, context).call do
        yield
      end
    end
  end
end
