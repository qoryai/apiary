defmodule ApiaryWeb.EndpointPlainHttpTest do
  # Not async: the last test sets the endpoint's configuration in the application's
  # environment, which other tests read.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ApiaryWeb.Endpoint

  @fix "Set PUBLIC_URL to an https:// address, or nobody can sign in."

  # The endpoint's `url:` as config/runtime.exs derives it from a PUBLIC_URL.
  defp url(public_url) do
    uri = URI.parse(public_url)
    [scheme: uri.scheme, host: uri.host, port: uri.port]
  end

  describe "sign_in_cookies_dropped?/1" do
    test "is true for plain http on a LAN host or a public name" do
      for public_url <- ["http://192.168.1.20:4100", "http://qory.example", "http://LAN-box"] do
        assert Endpoint.sign_in_cookies_dropped?(url(public_url)), public_url
      end
    end

    test "is false for https, and for plain http on localhost and the loopback addresses" do
      for public_url <- [
            "https://qory.example",
            "https://192.168.1.20:4100",
            "http://localhost:4100",
            "http://LocalHost",
            "http://app.localhost:4100",
            "http://127.0.0.1:4100",
            "http://127.0.0.2:4100",
            "http://[::1]:4100",
            "http://[0:0:0:0:0:0:0:1]:4100"
          ] do
        refute Endpoint.sign_in_cookies_dropped?(url(public_url)), public_url
      end
    end

    test "is false for a url without a scheme" do
      refute Endpoint.sign_in_cookies_dropped?(host: "qory.example")
    end
  end

  describe "the warning" do
    test "is logged once, with the fix on its first line and PUBLIC_URL after" do
      log =
        capture_log(fn ->
          assert Endpoint.warn_plain_http(url("http://192.168.1.20:4100")) == :ok
        end)

      assert length(String.split(log, @fix)) == 2

      assert log =~
               "Browsers keep the sign-in cookies over plain http only on localhost and loopback addresses; " <>
                 "PUBLIC_URL is http://192.168.1.20:4100."
    end

    test "names a PUBLIC_URL without a port as it is" do
      log = capture_log(fn -> Endpoint.warn_plain_http(url("http://qory.example")) end)
      assert log =~ "PUBLIC_URL is http://qory.example."
    end

    test "is not logged for https or localhost" do
      for public_url <- ["https://qory.example", "http://localhost:4100", "http://[::1]:4100"] do
        log = capture_log(fn -> assert Endpoint.warn_plain_http(url(public_url)) == :ok end)
        refute log =~ @fix
      end
    end

    test "is logged at boot only when the endpoint serves" do
      endpoint = Application.get_env(:apiary, Endpoint)
      on_exit(fn -> Application.put_env(:apiary, Endpoint, endpoint) end)
      lan = [scheme: "http", host: "192.168.1.20", port: 4100]

      Application.put_env(:apiary, Endpoint, Keyword.merge(endpoint, url: lan, server: false))
      log = capture_log(fn -> assert Endpoint.warn_plain_http() == :ok end)
      refute log =~ @fix

      Application.put_env(:apiary, Endpoint, Keyword.merge(endpoint, url: lan, server: true))
      log = capture_log(fn -> assert Endpoint.warn_plain_http() == :ok end)
      assert length(String.split(log, @fix)) == 2
      assert log =~ "PUBLIC_URL is http://192.168.1.20:4100."
    end
  end
end
