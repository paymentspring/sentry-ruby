module Sentry
  module Lambda
    class CaptureExceptions
      def initialize(event, context)
        @event = event
        @context = context
      end

      def call(&block)
        return yield unless Sentry.initialized?

        # make sure the current thread has a clean hub
        Sentry.clone_hub_to_current_thread

        Sentry.with_scope do |scope|
          scope.clear_breadcrumbs
          scope.set_transaction_name(@context.function_name)
          # TODO: sometning like - `scope.set_rack_env(env)`

          transaction = start_transaction(@event, @context, scope.transaction_name)
          scope.set_span(transaction) if transaction

          begin
            response = yield
          rescue Sentry::Error
            finish_transaction(transaction, 500)
            raise # Don't capture Sentry errors
          rescue Exception => e
            capture_exception(e)
            finish_transaction(transaction, 500)
            raise
          end

          finish_transaction(transaction, response[:statusCode])

          response
        end
      end

      def start_transaction(event, context, transaction_name)
        Sentry.start_transaction(
          transaction: nil,
          custom_sampling_context: {
            aws_event: event,
            aws_context: context
          },
          name: transaction_name, op: 'serverless.function'
        )
      end

      def start_transaction(event, context, transaction_name)
        sentry_trace = event["HTTP_SENTRY_TRACE"]
        options = { name: transaction_name, op: 'serverless.function' }
        transaction = Sentry::Transaction.from_sentry_trace(sentry_trace, **options) if sentry_trace
        Sentry.start_transaction(transaction: transaction, **options)
      end

      def finish_transaction(transaction, status_code)
        return unless transaction

        transaction.set_http_status(status_code)
        transaction.finish
      end

      def capture_exception(exception)
        Sentry.capture_exception(exception)
      end
    end
  end
end
