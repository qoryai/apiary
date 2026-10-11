defmodule Apiary.DatabaseUrlTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Apiary.DatabaseUrl

  @refused """
  Use sslmode=verify-full, which checks the server's certificate, or sslmode=require, which encrypts without checking it.
  """

  @unchecked "The database connection is encrypted, and the server's certificate is not checked (sslmode=require)."

  defp options(url, password \\ nil), do: DatabaseUrl.repo_options(url, password)

  # A formatter for capture_log/2 that writes the messages of one process, the test's, and
  # nothing of any other. capture_log/2 takes every process's log, and this module runs
  # beside others, so a test that asserts nothing is logged reads its own process's
  # messages only.
  #
  # Not a :logger handler of its own: OTP's logger_server writes back the list of handlers
  # it read when a removal arrived, so removing one while another test's capture_log/2
  # removes ExUnit's puts ExUnit's back in the list, and every capture after that, in every
  # test, sees each line twice.
  defmodule OwnLog do
    @moduledoc false
    def format(%{meta: %{pid: pid}} = event, {pid, {formatter, config}}),
      do: formatter.format(event, config)

    def format(_event, _config), do: []
  end

  # The messages this process logs while `fun` runs.
  defp own_log(fun) do
    formatter = Logger.Formatter.new(format: "$message\n", colors: [enabled: false])

    [formatter: {OwnLog, {self(), formatter}}]
    |> capture_log(fun)
    |> String.split("\n", trim: true)
  end

  # What Ecto makes of the options, as Ecto.Repo.Supervisor merges them.
  defp ecto(options) do
    {url, config} = Keyword.pop(options, :url)
    Keyword.merge(config, Ecto.Repo.Supervisor.parse_url(url))
  end

  describe "sslmode" do
    test "none: the URL as it is, and no ssl option, Ecto's own ssl=true still working" do
      for url <- [
            "postgres://apiary:pw@db.example.com/apiary",
            "ecto://apiary:pw@db.example.com:5433/apiary?pool_size=5"
          ] do
        assert options(url) == [url: url]
      end

      url = "postgres://apiary:pw@db.example.com/apiary?ssl=true"
      assert options(url) == [url: url]
      assert ecto(options(url))[:ssl] == true
    end

    test "disable: no TLS, whatever Ecto's ssl says" do
      for url <- [
            "postgres://apiary:pw@db.example.com/apiary?sslmode=disable",
            "postgres://apiary:pw@db.example.com/apiary?ssl=true&sslmode=disable"
          ] do
        assert options(url) == [url: "postgres://apiary:pw@db.example.com/apiary", ssl: false]
        assert ecto(options(url))[:ssl] == false
      end
    end

    test "verify-full: Postgrex's secure defaults, the system's CAs, certificate and host checked" do
      for query <- ["sslmode=verify-full", "sslmode=verify-full&sslrootcert=system"] do
        options = options("postgres://apiary:pw@db.example.com/apiary?" <> query)
        assert options == [url: "postgres://apiary:pw@db.example.com/apiary", ssl: true]
      end
    end

    @tag :tmp_dir
    test "verify-full with sslrootcert=/path: that file's CAs, certificate and host checked",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "ca.pem")
      File.write!(path, "-----BEGIN CERTIFICATE-----\n")

      url =
        "postgres://apiary:pw@db.example.com/apiary?sslmode=verify-full&sslrootcert=" <>
          URI.encode_www_form(path)

      assert options(url) == [
               url: "postgres://apiary:pw@db.example.com/apiary",
               ssl: [cacertfile: path]
             ]

      # Postgrex merges the list over its defaults, which check the certificate and the host.
      assert ecto(options(url))[:ssl] == [cacertfile: path]
    end

    @tag :tmp_dir
    test "verify-full with an sslrootcert that cannot be read stops the boot, naming the path",
         %{tmp_dir: tmp_dir} do
      for path <- [Path.join(tmp_dir, "missing.pem"), tmp_dir] do
        url =
          "postgres://apiary:pw@db.example.com/apiary?sslmode=verify-full&sslrootcert=" <>
            URI.encode_www_form(path)

        error = assert_raise RuntimeError, fn -> options(url) end

        assert error.message == """
               environment variable DATABASE_URL names sslrootcert=#{path}, which cannot be read.
               """
      end
    end

    test "require: TLS without checking the certificate; sslrootcert is not read" do
      for query <- [
            "sslmode=require",
            "sslmode=require&sslrootcert=/nowhere/ca.pem",
            "ssl=false&sslmode=require"
          ] do
        options = options("postgres://apiary:pw@db.example.com/apiary?" <> query)

        assert options == [
                 url: "postgres://apiary:pw@db.example.com/apiary",
                 ssl: [verify: :verify_none]
               ]
      end
    end

    test "prefer, allow, verify-ca, or anything else stops the boot, saying which to use" do
      for mode <- ["prefer", "allow", "verify-ca", "VERIFY-FULL", "true", ""] do
        url = "postgres://apiary:pw@db.example.com/apiary?sslmode=#{mode}"
        error = assert_raise RuntimeError, fn -> options(url) end

        assert error.message ==
                 "environment variable DATABASE_URL asks sslmode=#{mode}, which Qory does not take.\n" <>
                   @refused
      end
    end

    test "the last of a repeated sslmode wins, as in libpq" do
      url = "postgres://apiary:pw@db.example.com/apiary?sslmode=prefer&sslmode=verify-full"
      assert options(url)[:ssl] == true
    end
  end

  describe "the URL Ecto is given" do
    test "is left without sslmode and sslrootcert, every other key as it was written" do
      url =
        "postgres://apiary:p%40ss@db.example.com:5433/apiary?pool_size=5&sslmode=verify-full" <>
          "&application_name=a+b%2Fc&sslrootcert=system&timeout=1000"

      options = options(url)

      assert options[:url] ==
               "postgres://apiary:p%40ss@db.example.com:5433/apiary?pool_size=5" <>
                 "&application_name=a+b%2Fc&timeout=1000"

      ecto = ecto(options)
      refute Keyword.has_key?(ecto, :sslmode)
      refute Keyword.has_key?(ecto, :sslrootcert)
      assert ecto[:password] == "p@ss"
      assert ecto[:port] == 5433
      assert ecto[:pool_size] == 5
      assert ecto[:application_name] == "a b/c"
    end

    test "an IPv6 host keeps its brackets" do
      url = "postgres://apiary:pw@[2001:db8::1]:5432/apiary?sslmode=require"
      assert options(url)[:url] == "postgres://apiary:pw@[2001:db8::1]:5432/apiary"
      assert ecto(options(url))[:hostname] == "2001:db8::1"
    end
  end

  describe "DATABASE_PASSWORD" do
    test "is the password when the URL carries none" do
      for url <- ["postgres://apiary@db.example.com/apiary", "postgres://db.example.com/apiary"] do
        options = options(url, "from-env")
        assert options == [url: url, password: "from-env"]
        assert ecto(options)[:password] == "from-env"
      end
    end

    test "is not used when the URL carries a password" do
      url = "postgres://apiary:in-url@db.example.com/apiary"
      assert options(url, "from-env") == [url: url]
      assert ecto(options(url, "from-env"))[:password] == "in-url"
    end

    test "an empty password in the URL is none, and is taken out of it" do
      options = options("postgres://apiary:@db.example.com/apiary?sslmode=require", "from-env")

      assert options == [
               url: "postgres://apiary@db.example.com/apiary",
               ssl: [verify: :verify_none],
               password: "from-env"
             ]

      assert ecto(options)[:password] == "from-env"
    end

    test "unset or empty, the URL alone decides" do
      for password <- [nil, ""] do
        assert options("postgres://apiary@db.example.com/apiary", password) == [
                 url: "postgres://apiary@db.example.com/apiary"
               ]
      end
    end

    test "is passed as it is, with characters a URL would have to encode" do
      options = options("postgres://apiary@db.example.com/apiary", "p@ss:w/rd%")
      assert ecto(options)[:password] == "p@ss:w/rd%"
    end
  end

  describe "the warning for sslmode=require" do
    test "is logged once at boot" do
      options = options("postgres://apiary:pw@db.example.com/apiary?sslmode=require")
      log = capture_log(fn -> assert DatabaseUrl.warn_unchecked(options) == :ok end)
      assert length(String.split(log, @unchecked)) == 2
    end

    test "is not logged for the other modes" do
      for query <- ["", "?sslmode=disable", "?sslmode=verify-full", "?ssl=true"] do
        options = options("postgres://apiary:pw@db.example.com/apiary" <> query)
        assert own_log(fn -> DatabaseUrl.warn_unchecked(options) end) == []
      end
    end
  end
end
