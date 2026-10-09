defmodule Apiary.DatabaseUrlTlsTest do
  # Against a Postgres that serves TLS with a certificate for `localhost`, signed by a CA made
  # for the run: CI's job "Database over TLS" starts one and runs `mix test --only
  # database_tls`. The environment names it: DATABASE_TLS_PORT on 127.0.0.1, the password of
  # the role postgres in DATABASE_TLS_PASSWORD, the CA in DATABASE_TLS_CA, and a CA that did
  # not sign the certificate in DATABASE_TLS_WRONG_CA.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :database_tls

  @ssl_in_use "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()"

  defp url(host, query) do
    port = System.fetch_env!("DATABASE_TLS_PORT")
    "postgres://postgres@#{host}:#{port}/postgres?" <> query
  end

  defp rootcert(name), do: "sslrootcert=" <> URI.encode_www_form(System.fetch_env!(name))

  # Connects with the options `Apiary.DatabaseUrl` makes, as Ecto merges them, the password
  # in DATABASE_PASSWORD's place: `{:ok, whether TLS is in use}`, or `{:error, log}` with
  # what the refused connection logged. One attempt: a refused one stops the pool, and the
  # query waits for that attempt however long a loaded machine takes.
  defp connect(url) do
    options = Apiary.DatabaseUrl.repo_options(url, System.fetch_env!("DATABASE_TLS_PASSWORD"))
    {url, config} = Keyword.pop(options, :url)
    options = Keyword.merge(config, Ecto.Repo.Supervisor.parse_url(url))
    Process.flag(:trap_exit, true)

    {result, log} =
      with_log(fn ->
        {:ok, pid} =
          Postgrex.start_link(
            options ++
              [pool_size: 1, backoff_type: :stop, queue_target: 60_000, queue_interval: 60_000]
          )

        try do
          %Postgrex.Result{rows: [[ssl]]} = Postgrex.query!(pid, @ssl_in_use, [])
          GenServer.stop(pid)
          {:ok, ssl}
        catch
          :exit, _ -> :error
        end
      end)

    if result == :error, do: {:error, log}, else: result
  end

  test "verify-full with sslrootcert naming the CA connects over TLS" do
    assert connect(url("localhost", "sslmode=verify-full&" <> rootcert("DATABASE_TLS_CA"))) ==
             {:ok, true}
  end

  test "verify-full refuses a certificate the named CA did not sign" do
    url = url("localhost", "sslmode=verify-full&" <> rootcert("DATABASE_TLS_WRONG_CA"))
    assert {:error, log} = connect(url)
    assert log =~ "Unknown CA"
  end

  test "verify-full refuses a host name the certificate does not name" do
    url = url("127.0.0.1", "sslmode=verify-full&" <> rootcert("DATABASE_TLS_CA"))
    assert {:error, log} = connect(url)
    assert log =~ "hostname_check_failed"
  end

  test "verify-full against the system's CAs refuses the run's own CA" do
    assert {:error, log} = connect(url("localhost", "sslmode=verify-full&sslrootcert=system"))
    assert log =~ "Unknown CA"
  end

  test "require connects over TLS without checking the certificate, and logs nothing per connection" do
    url = url("127.0.0.1", "sslmode=require&" <> rootcert("DATABASE_TLS_WRONG_CA"))
    log = capture_log(fn -> assert connect(url) == {:ok, true} end)
    assert log == ""
  end

  test "disable connects without TLS" do
    assert connect(url("localhost", "sslmode=disable")) == {:ok, false}
  end
end
