require "open3"

# 標準出力のバッファリングを無効化
STDOUT.sync = true

# ログ記録用クラス
class LogOutput
  # 標準出力を抑制してファイルへ出力スタート
  def self.start
    logname = "/var/log/httpd/http_header_log." + Time.new.strftime("%Y-%m-%d")
    file = open(logname, 'a')
    # ファイル書き込みのバッファリングを無効化
    file.sync = true
    # 標準出力をファイル出力へ切り替え
    $stdout = file
  end

  # ファイルへの出力を停止して標準出力へ戻す
  def self.stop
    $stdout.close
    $stdout = STDOUT
  end
end # class LogOutput

# tcpdumpを実行して標準出力へ渡す
Open3.popen3("/sbin/tcpdump -i eth1 port 80 -Anns 2000 -l 2>&1") do |stdin, stdout, stderr, wait_thr|
  # 標準入力を閉じる
  stdin.close_write

  begin
    # ログ記録開始
    LogOutput.start

    http_header = ""
    request = []
    response = []

    # 標準出力、標準エラーの出力があるまで延々と待ち、随時1行ずつ書き出す
    loop do
      IO.select([stdout, stderr]).flatten.compact.each do |io|
        io.each do |line|
          next if line.nil? || line.empty?
          http_header << line

          # リクエストヘッダ処理
          # 配列の中に {:seq 数値, :header "リクエストヘッダ全体文字列"} のハッシュを格納する
          while http_header =~ /\A.*?(\d\d:\d\d:\d\d\..*?\n).*?((?:GET|POST) .*?\r\n)\r\n/m
            hash = {seq: $1, header: $1 + $2, time: Time.now}
            # TCPヘッダ1行目のシーケンス番号をハッシュキーとして上書き
            hash[:seq] = $1.to_i if hash[:seq] =~ /seq \d+:(\d+)/
            # キャプチャ元から配列に入れた部分は削除して上書き
            http_header = $1 + $2 if http_header =~ /\A(.*?)\d\d:\d\d:\d\d\..*?\n.*?(?:GET|POST) .*?\r\n\r\n(.*)\z/m
            request.push(hash) unless hash.empty?
            hash = {}
          end

          # レスポンスヘッダ処理
          # 配列の中に {:ack 数値, :header "レスポンスヘッダ全体文字列"} のハッシュを格納する
          while http_header =~ /\A.*?(\d\d:\d\d:\d\d\..*?\n).*?(HTTP\/[12](?:\.[01])? (\d{3}) .*?\r\n)\r\n/m
            # ステータスコード status: も格納しておいて、絞り込みに利用できるようにしておく
            hash = {ack: $1, header: "\n" + $1 + $2, status: $3.to_i, time: Time.now}
            # TCPヘッダ1行目のackの数値をハッシュキーとして上書き
            hash[:ack] = $1.to_i if hash[:ack] =~ /ack (\d+)/
            # レスポンスは行頭に"> "付きで記録する
            hash[:header].gsub!(/^/, "> ")
            # キャプチャ元から配列に入れた部分は削除して上書き
            http_header = $1 + $2 if http_header =~ /\A(.*?)\d\d:\d\d:\d\d\..*?\n.*?HTTP\/[12](?:\.[01])? \d{3} .*?\r\n\r\n(.*)\z/m
            response.push(hash) unless hash.empty?
            hash = {}
          end

          # リクエストヘッダ配列、レスポンスヘッダ配列共にデータが入っている場合
          unless request.empty? && response.empty?
            i = 0
            while i < request.count
              tmp = []
              response.each { |v| tmp.push(v.values_at(:ack)).flatten! }
              # リクエストのシーケンス番号でレスポンスのackを検索して、最初にマッチした添字で紐付ける
              if response_index = tmp.index(request[i][:seq])
                # リクエストヘッダとレスポンスヘッダをペアで出力
                puts request[i][:header], response[response_index][:header], "\n"
                # 出力した場合は配列から削除
                request.delete_at(i)
                response.delete_at(response_index)
                next # 配列から削除した場合は i へ加算せずにループ継続
              end
              i += 1
            end
          end

          # 格納してから300秒以上経った要素は削除
          request.delete_if { |v| v[:time] < Time.now - 300 }
          response.delete_if { |v| v[:time] < Time.now - 300 }

          # ループ前にhttp_headerのゴミ掃除（最後のキャプチャブロックのみ残す）
          http_header = $1 if http_header =~ /\A.*\n(\d\d:\d\d:\d\d\.\d{6}.*?)\z/m

        end # io.each
      end # IO.select([stdout, stderr]).flatten.compact.each

      # 標準出力、標準エラーでEOFが検知された、つまり外部コマンドの実行が終了したらループを抜ける
      break if stdout.eof? && stderr.eof?
    end # loop

    puts "EOF検知でループ終了"

    # ログ記録終了
    LogOutput.stop

  # エラー処理
  rescue => e
    puts e.class
    puts e.message
    puts e.backtrace
  end
end
