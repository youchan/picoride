module PicorubyEsp32Ide
  class BackgroundJob
    # ブラウザ(PicoRuby.wasm)側でのJSONパース/描画が重くなりすぎないよう、
    # API経由で返すログは末尾のみに切り詰める。全量は @state[:log] に残る。
    LOG_TAIL_LIMIT = 8_000

    def initialize
      @mutex = Mutex.new
      @state = { status: "idle", log: "", started_at: nil, finished_at: nil }
    end

    # 実行中でなければバックグラウンドスレッドでcmdを開始してtrueを返す。
    # 実行中ならなにもせずfalseを返す(呼び出し側で409にする)。
    def start(cmd)
      started = @mutex.synchronize do
        break false if @state[:status] == "running"

        @state[:status] = "running"
        @state[:log] = ""
        @state[:started_at] = Time.now.to_i
        @state[:finished_at] = nil
        true
      end

      Thread.new { run(cmd) } if started
      started
    end

    def running?
      @mutex.synchronize { @state[:status] == "running" }
    end

    def to_response_json
      @mutex.synchronize do
        full_log = @state[:log]
        truncated = full_log.length > LOG_TAIL_LIMIT

        {
          status: @state[:status],
          log: truncated ? full_log[-LOG_TAIL_LIMIT..-1] : full_log,
          log_truncated: truncated,
          started_at: @state[:started_at],
          finished_at: @state[:finished_at]
        }.to_json
      end
    end

    private

    def run(cmd)
      Open3.popen2e("bash", "-c", cmd) do |stdin, stdout_and_stderr, wait_thread|
        stdin.close
        stdout_and_stderr.each_line do |line|
          @mutex.synchronize { @state[:log] << line }
        end

        success = wait_thread.value.success?
        @mutex.synchronize do
          @state[:status] = success ? "success" : "failed"
          @state[:finished_at] = Time.now.to_i
        end
      end
    rescue StandardError => e
      @mutex.synchronize do
        @state[:status] = "failed"
        @state[:log] << "\n[#{e.class}] #{e.message}\n"
        @state[:finished_at] = Time.now.to_i
      end
    end
  end
end
