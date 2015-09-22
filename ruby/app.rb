require 'sinatra/base'
require 'json'
require 'mysql2-cs-bind'
require 'digest/sha2'
require 'dalli'
require 'rack/session/dalli'
require 'erubis'
require 'tempfile'
require 'redcarpet'
require 'redis'
require 'hiredis'

class Isucon3App < Sinatra::Base
  $stdout.sync = true
  use Rack::Session::Dalli, {
    :key => 'isucon_session',
    :cache => Dalli::Client.new('localhost:11212')
  }

  helpers do
    set :erb, :escape_html => true

    def redis
      @redis ||= Redis.new(driver: :hiredis)
    end

    def users
      unless @users
        @users = {}
        # id, username, password, salt
        columns = %w(id username password salt)
        IO.read(File.dirname(__FILE__) + "/../config/users.tsv").strip.split("\n").each do |user|
          user_hash = Hash[columns.zip(user.strip.split("\t")[0..-1])]
          user_hash['id'] = user_hash['id'].to_i
          @users[user_hash['id']] = user_hash
        end

        open(File.dirname(__FILE__) + "/../config/users.debug", "w+") do |f|
          f.puts @users.inspect
        end
      end

      @users
    end

    def users_by_username
      unless @users_by_username
        @users_by_username = {}
        users.values.each do |user|
          @users_by_username[user["username"]] = user
        end
      end

      @users_by_username
    end

    def connection
      return $mysql if $mysql

      config = JSON.parse(IO.read(File.dirname(__FILE__) + "/../config/#{ ENV['ISUCON_ENV'] || 'local' }.json"))['database']
      $mysql = Mysql2::Client.new(
        :host => config['host'],
        :port => config['port'],
        :username => config['username'],
        :password => config['password'],
        :database => config['dbname'],
        :reconnect => true,
      )
    end

    def markdown
      @markdown ||= Redcarpet::Markdown.new(Redcarpet::Render::HTML)
    end

    def get_user
      mysql = connection
      user_id = session["user_id"]
      if user_id
        user = users[user_id]
        headers "Cache-Control" => "private"
      end
      return user || {}
    end

    def require_user(user)
      unless user["username"]
        redirect "/"
        halt
      end
    end

    def gen_markdown(md)
      markdown.render(md)
    end

    def anti_csrf
      if params["sid"] != session["token"]
        halt 400, "400 Bad Request"
      end
    end

    def url_for(path)
      scheme = request.scheme
      if (scheme == 'http' && request.port == 80 ||
          scheme == 'https' && request.port == 443)
        port = ""
      else
        port = ":#{request.port}"
      end
      base = "#{scheme}://#{request.host}#{port}#{request.script_name}"
      "#{base}#{path}"
    end
  end

  get '/' do
    mysql = connection
    user  = get_user

    total = mysql.query("SELECT count(*) AS c FROM memos WHERE is_private=0").first["c"]
    memos = mysql.query("SELECT * FROM memos WHERE is_private=0 ORDER BY created_at DESC, id DESC LIMIT 100")
    memos.each do |row|
      row["username"] = users[row["user"].to_i]["username"]
    end
    erb :index, :layout => :base, :locals => {
      :memos => memos,
      :page  => 0,
      :total => total,
      :user  => user,
    }
  end

  get '/recent/:page' do
    mysql = connection
    user  = get_user

    page  = params["page"].to_i
    total = mysql.xquery('SELECT count(*) AS c FROM memos WHERE is_private=0').first["c"]
    memos = mysql.xquery("SELECT * FROM memos WHERE is_private=0 ORDER BY created_at DESC, id DESC LIMIT 100 OFFSET #{page * 100}")
    if memos.count == 0
      halt 404, "404 Not Found"
    end
    memos.each do |row|
      row["username"] = users[row["user"].to_i]["username"]
    end
    erb :index, :layout => :base, :locals => {
      :memos => memos,
      :page  => page,
      :total => total,
      :user  => user,
    }
  end

  post '/signout' do
    user = get_user
    require_user(user)
    anti_csrf

    session.destroy
    redirect "/"
  end

  get '/signin' do
    user = get_user
    erb :signin, :layout => :base, :locals => {
      :user => user,
    }
  end

  post '/signin' do
    username = params[:username]
    password = params[:password]
    user = users_by_username[username]
    if user && user["password"] == Digest::SHA256.hexdigest(user["salt"] + password)
      session.clear
      session["user_id"] = user["id"]
      session["token"] = Digest::SHA256.hexdigest(Random.new.rand.to_s)
      redirect "/mypage"
    else
      erb :signin, :layout => :base, :locals => {
        :user => {},
      }
    end
  end

  get '/mypage' do
    mysql = connection
    user  = get_user
    require_user(user)

    memos = mysql.xquery('SELECT id, content, is_private, created_at, updated_at FROM memos WHERE user=? ORDER BY created_at DESC', user["id"])
    erb :mypage, :layout => :base, :locals => {
      :user  => user,
      :memos => memos,
    }
  end

  get '/memo/:memo_id' do
    mysql = connection
    user  = get_user

    memo = mysql.xquery('SELECT id, user, content, is_private, created_at, updated_at FROM memos WHERE id=?', params[:memo_id]).first
    unless memo
      halt 404, "404 Not Found"
    end
    if memo["is_private"] == 1
      if user["id"] != memo["user"]
        halt 404, "404 Not Found"
      end
    end

    memo["username"] = users[memo["user"].to_i]["username"]
    memo["content_html"] = redis.get("isucon3:memo:html:#{memo["id"]}")

    if user["id"] == memo["user"]
      cond = ""
    else
      cond = "AND is_private=0"
    end
    memos = []
    older = nil
    newer = nil
    results = mysql.xquery("SELECT * FROM memos WHERE user=? #{cond} ORDER BY created_at", memo["user"])
    results.each do |m|
      memos.push(m)
    end
    0.upto(memos.count - 1).each do |i|
      if memos[i]["id"] == memo["id"]
        older = memos[i - 1] if i > 0
        newer = memos[i + 1] if i < memos.count
      end
    end
    erb :memo, :layout => :base, :locals => {
      :user  => user,
      :memo  => memo,
      :older => older,
      :newer => newer,
    }
  end

  post '/memo' do
    mysql = connection
    user  = get_user
    require_user(user)
    anti_csrf

    mysql.xquery(
      'INSERT INTO memos (user, content, is_private, created_at) VALUES (?, ?, ?, ?)',
      user["id"],
      params["content"],
      params["is_private"].to_i,
      Time.now,
    )
    memo_id = mysql.last_id
    redis.set("isucon3:memo:html:#{memo_id}", gen_markdown(params["content"]))

    redirect "/memo/#{memo_id}"
  end

  run! if app_file == $0
end
