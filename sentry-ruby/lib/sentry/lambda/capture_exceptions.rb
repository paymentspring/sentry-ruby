module Sentry
  module Lambda
    class CaptureExceptions
      def initialize(aws_event, aws_context)
        @aws_event = aws_event
        @aws_context = aws_context
      end

      def call(&block)
        return yield unless Sentry.initialized?

        # make sure the current thread has a clean hub
        Sentry.clone_hub_to_current_thread

        Sentry.with_scope do |scope|
          start_time = Time.now.utc
          puts "start_time ::: #{start_time}"
          initial_remaining_time_in_milis = @aws_context.get_remaining_time_in_millis
          puts "initial_remaining_time_in_milis ::: #{initial_remaining_time_in_milis}"
          execution_expiration_time = Time.now.utc + ((initial_remaining_time_in_milis || 0)/1000.0)
          puts "execution_expiration_time ::: #{execution_expiration_time}"

          scope.clear_breadcrumbs
          scope.set_transaction_name(@aws_context.function_name)

          scope.add_event_processor do |event, hint|
            event_time = Time.parse(event.timestamp) rescue Time.now.utc
            remaining_time_in_millis = ((execution_expiration_time - event_time) * 1000).round
            execution_duration_in_millis = ((event_time - start_time) * 1000).round
            event.extra = event.extra.merge(
              lambda: {
                function_name: @aws_context.function_name,
                function_version: @aws_context.function_version,
                invoked_function_arn: @aws_context.invoked_function_arn,
                aws_request_id: @aws_context.aws_request_id,
                execution_duration_in_millis: execution_duration_in_millis,
                remaining_time_in_millis: remaining_time_in_millis
              }
            )

            event
          end

          transaction = start_transaction(@aws_event, @aws_context, scope.transaction_name)
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
