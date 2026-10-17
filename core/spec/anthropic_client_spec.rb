require 'spec_helper'
require 'webmock/rspec'

RSpec.describe Muni::AnthropicClient do
  def stub_streaming_response
    capture = {}
    stub_request(:post, described_class::API_URL)
      .with do |request|
        capture[:body] = JSON.parse(request.body)
        capture[:headers] = request.headers
        true
      end
      .to_return(status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: anthropic_sse_body)
    capture
  end

  def anthropic_sse_body
    [
      "event: message_start\n" \
      "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":7}}}\n\n",
      "event: content_block_delta\n" \
      "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\n",
      "event: content_block_delta\n" \
      "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" Cambridge\"}}\n\n",
      "event: message_delta\n" \
      "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":5}}\n\n",
      "event: message_stop\n" \
      "data: {\"type\":\"message_stop\"}\n\n"
    ].join
  end

  def sample_stream(events, api_key: 'anthropic-key')
    described_class.new(api_key: api_key).stream(
      messages:   [{ role: 'user', content: 'hello' }],
      system:     'system prompt',
      max_tokens: 128
    ) { |event| events << event }
  end

  def expected_stream_events
    [
      {
        type:     'model_connecting',
        provider: 'anthropic',
        model:    described_class::DEFAULT_MODEL,
        label:    'Claude Sonnet'
      },
      {
        type:     'model_ready',
        provider: 'anthropic',
        model:    described_class::DEFAULT_MODEL,
        label:    'Claude Sonnet'
      },
      { type: 'thinking', input_tokens: 7 },
      { type: 'text_delta', text: 'Hello' },
      { type: 'text_delta', text: ' Cambridge' },
      { type: 'message_delta', output_tokens: 5 },
      { type: 'message_stop' }
    ]
  end

  around do |example|
    old_key = ENV.fetch('ANTHROPIC_API_KEY', nil)
    old_model = ENV.fetch('MUNI_ANTHROPIC_MODEL', nil)
    example.run
  ensure
    ENV['ANTHROPIC_API_KEY'] = old_key
    ENV['MUNI_ANTHROPIC_MODEL'] = old_model
  end

  it 'uses the current Sonnet model by default when an API key is present' do
    client = described_class.new(api_key: 'anthropic-key')

    expect(client).to be_configured
    expect(client.model).to eq(described_class::DEFAULT_MODEL)
    expect(client.provider).to eq('anthropic')
    expect(client.label).to eq('Claude Sonnet')
  end

  it 'requires an Anthropic API key' do
    client = described_class.new(api_key: nil)

    expect(client).not_to be_configured
  end

  it 'posts Messages API payloads and normalizes streaming events' do
    request = stub_streaming_response
    events = []
    sample_stream(events)

    expect(request[:body]).to include(
      'model'      => described_class::DEFAULT_MODEL,
      'max_tokens' => 128,
      'system'     => 'system prompt',
      'stream'     => true,
      'messages'   => [{ 'role' => 'user', 'content' => 'hello' }]
    )
    expect(request[:headers]).to include(
      'Accept'            => 'text/event-stream',
      'Anthropic-Version' => described_class::API_VERSION,
      'X-Api-Key'         => 'anthropic-key'
    )
    expect(events).to eq(expected_stream_events)
  end

  it 'surfaces Anthropic API error details' do
    stub_request(:post, described_class::API_URL)
      .to_return(
        status: 401,
        body:   JSON.dump(error: { message: 'invalid x-api-key' })
      )

    expect do
      sample_stream([], api_key: 'bad-key')
    end.to raise_error(described_class::Error, /Anthropic HTTP 401: invalid x-api-key/)
  end
end
