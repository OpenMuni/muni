require 'json'
require 'net/http'
require 'uri'

module Muni
  class AnthropicClient
    class Error < StandardError; end
    class ConfigurationError < Error; end

    API_URL = 'https://api.anthropic.com/v1/messages'.freeze
    API_VERSION = '2023-06-01'.freeze
    DEFAULT_MODEL = 'claude-sonnet-4-6'.freeze
    PROVIDER = 'anthropic'.freeze
    LABEL = 'Claude Sonnet'.freeze

    attr_reader :model, :provider, :label

    def initialize(api_key: ENV.fetch('ANTHROPIC_API_KEY', nil),
                   model: ENV.fetch('MUNI_ANTHROPIC_MODEL', DEFAULT_MODEL))
      @api_key = api_key.to_s.strip
      @model = model.to_s.strip.empty? ? DEFAULT_MODEL : model.to_s.strip
      @provider = PROVIDER
      @label = LABEL
    end

    def configured?
      !api_key.empty? && !model.empty?
    end

    def stream(messages:, system:, max_tokens:, tools: nil, &block)
      raise ConfigurationError, 'AI unavailable' unless configured?

      block.call(model_event('model_connecting'))
      request(messages: messages, system: system, max_tokens: max_tokens, tools: tools) do |event|
        block.call(event)
      end
    end

    # Non-streaming single completion, used for batch jobs (e.g. meeting
    # summaries) where we want one full text response rather than SSE events.
    # Returns { text:, model:, input_tokens:, output_tokens:, stop_reason: }.
    def complete(messages:, system:, max_tokens: 3000)
      raise ConfigurationError, 'AI unavailable' unless configured?

      uri = URI(API_URL)
      req = Net::HTTP::Post.new(uri)
      req['x-api-key'] = api_key
      req['anthropic-version'] = API_VERSION
      req['content-type'] = 'application/json'
      req.body = JSON.generate(model: model, max_tokens: max_tokens, system: system, messages: messages)

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 120) { |http| http.request(req) }
      body = res.body.to_s
      raise Error, anthropic_error_message(res.code, body) unless res.is_a?(Net::HTTPSuccess)

      parse_completion(body)
    end

    private

    def parse_completion(body)
      data = JSON.parse(body)
      text = Array(data['content']).select { |b| b['type'] == 'text' }.map { |b| b['text'] }.join
      usage = data['usage'] || {}
      {
        text:          text.to_s.strip,
        model:         data['model'] || model,
        input_tokens:  usage['input_tokens'],
        output_tokens: usage['output_tokens'],
        stop_reason:   data['stop_reason']
      }
    rescue JSON::ParserError => e
      raise Error, "Malformed AI response: #{e.message}"
    end

    attr_reader :api_key

    def request(messages:, system:, max_tokens:, tools:, &block)
      uri = URI(API_URL)
      req = Net::HTTP::Post.new(uri)
      req['x-api-key'] = api_key
      req['anthropic-version'] = API_VERSION
      req['content-type'] = 'application/json'
      req['accept'] = 'text/event-stream'
      req.body = JSON.generate(payload(messages: messages, system: system, max_tokens: max_tokens, tools: tools))

      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.request(req) do |res|
          raise Error, anthropic_error_message(res.code, res.read_body.to_s) unless res.is_a?(Net::HTTPSuccess)

          block.call(model_event('model_ready'))
          parse_sse(res, &block)
        end
      end
    end

    def model_event(type)
      {
        type:     type,
        provider: provider,
        model:    model,
        label:    label
      }
    end

    def payload(messages:, system:, max_tokens:, tools:)
      body = {
        model:      model,
        max_tokens: max_tokens,
        system:     system,
        messages:   messages,
        stream:     true
      }
      body[:tools] = tools if tools && !tools.empty?
      body
    end

    def parse_sse(response)
      buffer = +''
      response.read_body do |chunk|
        buffer << chunk
        buffer.gsub!("\r\n", "\n")
        while (idx = buffer.index("\n\n"))
          frame = buffer.slice!(0, idx + 2)
          event = parse_frame(frame)
          yield(event) if event
        end
      end
    end

    def parse_frame(frame)
      event_type = nil
      data = []
      frame.each_line do |line|
        line = line.chomp
        next if line.empty?

        if line.start_with?('event:')
          event_type = line.sub('event:', '').strip
        elsif line.start_with?('data:')
          data << line.sub('data:', '').strip
        end
      end
      return nil if data.empty? || data.join == '[DONE]'

      normalize_anthropic_event(event_type, JSON.parse(data.join("\n")))
    rescue JSON::ParserError => e
      { type: 'error', message: "Malformed AI stream event: #{e.message}" }
    end

    def normalize_anthropic_event(event_type, payload) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      case event_type || payload['type']
      when 'message_start'
        usage = payload.dig('message', 'usage') || {}
        { type: 'thinking', input_tokens: usage['input_tokens'] }
      when 'content_block_start'
        block_data = payload['content_block'] || {}
        { type: 'tool_use_start', id: block_data['id'], name: block_data['name'] } if block_data['type'] == 'tool_use'
      when 'content_block_delta'
        delta = payload['delta'] || {}
        case delta['type']
        when 'text_delta'
          { type: 'text_delta', text: delta['text'] }
        when 'input_json_delta'
          { type: 'tool_input_delta', json: delta['partial_json'] }
        end
      when 'content_block_stop'
        { type: 'content_block_stop', index: payload['index'] }
      when 'message_delta'
        delta = payload['delta'] || {}
        usage = payload['usage'] || {}
        event = {}
        event[:stop_reason] = delta['stop_reason'] if delta['stop_reason']
        event[:output_tokens] = usage['output_tokens'] if usage['output_tokens']
        event.empty? ? nil : { type: 'message_delta' }.merge(event)
      when 'message_stop'
        { type: 'message_stop' }
      when 'error'
        { type: 'error', message: payload.dig('error', 'message') || 'AI stream error' }
      end
    end

    def anthropic_error_message(code, body)
      parsed = JSON.parse(body)
      detail = parsed.dig('error', 'message') || parsed['message']
      detail = body.strip if detail.to_s.empty?
      detail = 'request failed' if detail.to_s.empty?
      "Anthropic HTTP #{code}: #{detail}"
    rescue JSON::ParserError
      detail = body.strip.empty? ? 'request failed' : body.strip
      "Anthropic HTTP #{code}: #{detail}"
    end
  end
end
