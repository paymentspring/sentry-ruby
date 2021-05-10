require 'spec_helper'
require 'pry'

RSpec.describe Sentry::Lambda::CaptureExceptions do
  let(:exception) { ZeroDivisionError.new("divided by 0") }
  let(:additional_headers) { {} }
  let(:aws_event) do
    {}
  end
  let(:aws_context) do
    OpenStruct.new(
      function_name: 'my-function'
    )
  end
  let(:happy_response) do
    {
      statusCode: 200,
      body: {
        success: true,
        message: 'happy'
      }.to_json
    }
  end

  let(:transport) do
    Sentry.get_current_client.transport
  end

  describe "exceptions capturing" do
    before do
      perform_basic_setup
    end

    it "allows for shorthand syntax" do
      response = Sentry::Lambda.wrap_handler(event: aws_event, context: aws_context) do
        happy_response
      end

      expect(response).to eq(happy_response)
    end

    it 'captures the exception from direct raise' do
      app = ->(_e) { raise exception }
      stack = described_class.new(aws_event: aws_event, aws_context: aws_context)

      expect do
        stack.call do
          raise exception
        end
      end.to raise_error(ZeroDivisionError)

      event = transport.events.last
      # TODO: event does not have request
      # expect(event.to_hash.dig(:request, :url)).to eq("http://example.org/test")
    end

    xit 'sets the transaction and something like rack env' do
      app = lambda do |e|
        e['rack.exception'] = exception
        [200, {}, ['okay']]
      end
      stack = described_class.new(app)

      stack.call(env)

      event = transport.events.last
      expect(event.transaction).to eq("/test")
      # expect(event.to_hash.dig(:request, :url)).to eq("http://example.org/test")
      expect(Sentry.get_current_scope.transaction_names).to be_empty
      expect(Sentry.get_current_scope.rack_env).to eq({})
    end

    it 'returns happy result' do
      stack = described_class.new(aws_event: aws_event, aws_context: aws_context)
      expect do
        stack.call { happy_response }
      end.to_not raise_error
    end

    describe "state encapsulation" do
      before do
        Sentry.configure_scope { |s| s.set_tags(tag_1: "don't change me") }
      end

      it "only contains the breadcrumbs of the request" do
        logger = ::Logger.new(nil)

        logger.info("old breadcrumb")

        app_1 = described_class.new(aws_event: aws_event, aws_context: aws_context)

        app_1.call do
          logger.info("request breadcrumb")
          Sentry.capture_message("test")
          happy_response
        end

        event = transport.events.last
        expect(event.breadcrumbs.count).to eq(1)
        expect(event.breadcrumbs.peek.message).to eq("request breadcrumb")
      end
      it "doesn't pollute the top-level scope" do
        app_1 = described_class.new(aws_event: aws_event, aws_context: aws_context)

        app_1.call do
          Sentry.configure_scope { |s| s.set_tags({tag_1: "foo"}) }
          Sentry.capture_message("test")
          happy_response
        end

        event = transport.events.last
        expect(event.tags).to eq(tag_1: "foo")
        expect(Sentry.get_current_scope.tags).to eq(tag_1: "don't change me")
      end
      it "doesn't pollute other request's scope" do
        app_1 = described_class.new(aws_event: aws_event, aws_context: aws_context)
        app_1.call do
          Sentry.configure_scope { |s| s.set_tags({tag_1: "foo"}) }
          Sentry.capture_message('capture me')
          happy_response
        end

        event = transport.events.last
        expect(event.tags).to eq(tag_1: "foo")
        expect(Sentry.get_current_scope.tags).to eq(tag_1: "don't change me")

        app_2 = described_class.new(aws_event: aws_event, aws_context: aws_context)

        app_2.call do
          Sentry.configure_scope { |s| s.set_tags({tag_2: "bar"}) }
          Sentry.capture_message('capture me 2')
          happy_response
        end

        event = transport.events.last
        expect(event.tags).to eq(tag_2: "bar", tag_1: "don't change me")
        expect(Sentry.get_current_scope.tags).to eq(tag_1: "don't change me")
      end
    end
  end

  describe "performance monitoring" do
    before do
      perform_basic_setup do |config|
        config.traces_sample_rate = 0.5
      end
    end

    context "when the transaction is sampled" do
      before do
        allow(Random).to receive(:rand).and_return(0.4)
      end

      it "starts a span and finishes it" do
        described_class.new(aws_event: aws_event, aws_context: aws_context).call do
          happy_response
        end

        transaction = transport.events.last
        expect(transaction.type).to eq("transaction")
        expect(transaction.timestamp).not_to be_nil
        expect(transaction.contexts.dig(:trace, :status)).to eq("ok")
        expect(transaction.contexts.dig(:trace, :op)).to eq("serverless.function")
        expect(transaction.spans.count).to eq(0)
      end
    end

    context "when the transaction is not sampled" do
      before do
        allow(Random).to receive(:rand).and_return(0.6)
      end

      it "doesn't do anything" do
        described_class.new(aws_event: aws_event, aws_context: aws_context) do
          happy_response
        end

        expect(transport.events.count).to eq(0)
      end
    end

    context "when there's an exception" do
      before do
        allow(Random).to receive(:rand).and_return(0.4)
      end

      it "still finishes the transaction" do
        expect do
          described_class.new(aws_event: aws_event, aws_context: aws_context).call do
            raise 'foo'
          end
        end.to raise_error("foo")

        expect(transport.events.count).to eq(2)
        event = transport.events.first
        transaction = transport.events.last
        expect(event.contexts.dig(:trace, :trace_id).length).to eq(32)
        expect(event.contexts.dig(:trace, :trace_id)).to eq(transaction.contexts.dig(:trace, :trace_id))


        expect(transaction.type).to eq("transaction")
        expect(transaction.timestamp).not_to be_nil
        expect(transaction.contexts.dig(:trace, :status)).to eq("internal_error")
        expect(transaction.contexts.dig(:trace, :op)).to eq("serverless.function")
        expect(transaction.spans.count).to eq(0)
      end
    end

    context "when traces_sample_rate is not set" do
      before do
        Sentry.configuration.traces_sample_rate = nil
      end

      it "doesn't record transaction" do
        described_class.new(aws_event: aws_event, aws_context: aws_context) { happy_response }

        expect(transport.events.count).to eq(0)
      end

      context "when sentry-trace header is sent" do
        let(:external_transaction) do
          Sentry::Transaction.new(
            op: "pageload",
            status: "ok",
            sampled: true,
            name: "a/path",
            hub: Sentry.get_current_hub
          )
        end

        let(:aws_event) { { 'HTTP_SENTRY_TRACE' => external_transaction.to_sentry_trace } }

        it "doesn't cause the transaction to be recorded" do
          response = described_class.new(aws_event: aws_event, aws_context: aws_context).call { happy_response }

          expect(response[:statusCode]).to eq(200)
          expect(transport.events).to be_empty
        end
      end
    end
  end
end
