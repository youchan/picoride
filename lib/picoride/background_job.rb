module Picoride
  class BackgroundJob
    # ブラウザ(PicoRuby.wasm)側でのJSONパースが重くなりすぎないよう、ログは
    # offset以降の差分だけを、1レスポンスあたり最大LOG_CHUNK_LIMIT文字ずつ返す。
    # クライアントはnext_offsetを次のリクエストのoffsetに渡して追記していき、
    # more: true の間は続きをすぐ取りに来る(ログ全量を切り詰めずに表示するため)。
    LOG_CHUNK_LIMIT = 8_000

    def initialize
      @mutex = Mutex.new
      # run_id はジョブを開始するたびに増える。クライアントが持っているrun_idと
      # 違えば(新しいジョブが始まっていれば)offsetを無視して先頭から返す。
      @state = { status: "idle", log: "", run_id: 0, started_at: nil, finished_at: nil }
    end

    # 実行中でなければバックグラウンドスレッドでcmdを開始してtrueを返す。
    # 実行中ならなにもせずfalseを返す(呼び出し側で409にする)。
    def start(cmd)
      started = @mutex.synchronize do
        break false if @state[:status] == "running"

        @state[:status] = "running"
        @state[:log] = ""
        @state[:run_id] += 1
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

    # offset: クライアントが既に持っているログの長さ(前回レスポンスのnext_offset)
    # run_id: クライアントが持っているログのrun_id(前回レスポンスのrun_id)
    def to_response_json(offset: nil, run_id: nil)
      @mutex.synchronize do
        full_log = @state[:log]
        start = run_id.to_s == @state[:run_id].to_s ? offset.to_i : 0
        start = 0 if start < 0 || start > full_log.length
        chunk = full_log[start, LOG_CHUNK_LIMIT] || ""
        next_offset = start + chunk.length

        {
          status: @state[:status],
          run_id: @state[:run_id],
          log: chunk,
          offset: start,
          next_offset: next_offset,
          more: next_offset < full_log.length,
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
