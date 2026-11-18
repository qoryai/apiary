defmodule Apiary.ModelKeys.LoginDeviceTest do
  # The three calls of a device sign-in against a stub of the provider: what each call
  # reads from the response, and that a failure is one of the fixed words, never a part of the
  # response or the request.
  # Not async: one test sets the call time limit for the whole application.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Apiary.DeviceSignInStub, as: Stub
  alias Apiary.ModelKeys.LoginDevice

  @client "client-fixture"
  @code %{device_auth_id: "device-auth-fixture", user_code: "7QKD-M4TPX"}

  defp stub(fun), do: Req.Test.stub(LoginDevice, fun)

  describe "request_code/2" do
    test "reads the code, a string interval and the expiry" do
      Stub.script(code: "ABCD-1234", interval: "7")

      assert {:ok, %{user_code: "ABCD-1234", interval: 7, device_auth_id: "device-auth-fixture"}} =
               LoginDevice.request_code(Stub.device(), @client)
    end

    test "reads a number interval, bounds it and defaults a bad one" do
      for {sent, taken} <- [{3, 3}, {0, 1}, {900, 60}, {"x", 5}, {nil, 5}] do
        stub(fn conn ->
          Req.Test.json(conn, %{
            "device_auth_id" => "d",
            "usercode" => "C-1",
            "interval" => sent,
            "expires_at" => 4_102_444_800
          })
        end)

        assert {:ok, %{interval: ^taken, user_code: "C-1"}} =
                 LoginDevice.request_code(Stub.device(), @client)
      end
    end

    test "takes 15 minutes from now when expires_at is missing or unreadable" do
      for expires_at <- [
            :missing,
            "2026-11-18T10:00:00",
            "soon",
            "",
            1.5e9,
            nil,
            1_000_000_000_000_000_000_000,
            [1],
            %{}
          ] do
        Stub.script(expires_at: expires_at)

        assert {:ok, %{expires_at: at, user_code: "7QKD-M4TPX"}} =
                 LoginDevice.request_code(Stub.device(), @client)

        assert DateTime.diff(at, DateTime.utc_now()) in 895..900
      end
    end

    test "reads expires_at as an ISO 8601 text with an offset or as unix seconds" do
      Stub.script(expires_at: "2027-01-01T10:00:00+02:00")
      assert {:ok, %{expires_at: at}} = LoginDevice.request_code(Stub.device(), @client)
      assert at == ~U[2027-01-01 08:00:00Z]

      Stub.script(expires_at: 4_102_444_800)
      assert {:ok, %{expires_at: at}} = LoginDevice.request_code(Stub.device(), @client)
      assert at == ~U[2100-01-01 00:00:00Z]
    end

    test "is off for a 404, and a failure with the status for any other refusal" do
      stub(&Plug.Conn.send_resp(&1, 404, "{}"))
      assert LoginDevice.request_code(Stub.device(), @client) == :off

      stub(&Plug.Conn.send_resp(&1, 429, "{}"))
      assert LoginDevice.request_code(Stub.device(), @client) == {:error, "http_429"}
    end

    test "refuses a response that is no code" do
      for body <- ["", "[]", "not json", ~s({"user_code":"x"}), ~s({"device_auth_id":"d"})] do
        stub(&Plug.Conn.send_resp(&1, 200, body))
        assert LoginDevice.request_code(Stub.device(), @client) == {:error, "bad_response"}
      end
    end

    test "keeps at most 64 KiB of a response" do
      stub(&Plug.Conn.send_resp(&1, 200, String.duplicate("a", 70_000)))
      assert LoginDevice.request_code(Stub.device(), @client) == {:error, "bad_response"}
    end

    test "makes no call to an address the catalogue check refuses" do
      for url <- ["http://auth.example.test/x", "https://localhost/x", "https://127.0.0.1/x", nil] do
        assert LoginDevice.request_code(%{"usercode_url" => url}, @client) ==
                 {:error, "bad_endpoint"}
      end

      assert LoginDevice.request_code(%{}, @client) == {:error, "bad_endpoint"}
    end

    test "follows no redirect" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://auth.example.test/elsewhere")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert LoginDevice.request_code(Stub.device(), @client) == {:error, "http_302"}
    end

    test "turns a transport error into network, and writes no log line" do
      stub(&Req.Test.transport_error(&1, :econnrefused))

      log =
        capture_log(fn ->
          assert LoginDevice.request_code(Stub.device(), @client) == {:error, "network"}
        end)

      assert log == ""
    end

    test "stops a call that takes longer than the total time" do
      Application.put_env(
        :apiary,
        LoginDevice,
        Application.get_env(:apiary, LoginDevice) ++ [total_timeout: 50]
      )

      on_exit(fn ->
        Application.put_env(
          :apiary,
          LoginDevice,
          Keyword.delete(Application.get_env(:apiary, LoginDevice), :total_timeout)
        )
      end)

      stub(fn conn ->
        Process.sleep(500)
        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      assert LoginDevice.request_code(Stub.device(), @client) == {:error, "timeout"}
    end
  end

  describe "poll/2" do
    test "is pending for a 403 or a 404, and reads the grant of a 200" do
      for status <- [403, 404] do
        stub(&Plug.Conn.send_resp(&1, status, "{}"))
        assert LoginDevice.poll(Stub.device(), @code) == :pending
      end

      stub(fn conn ->
        Req.Test.json(conn, %{"authorization_code" => "a", "code_verifier" => "v"})
      end)

      assert LoginDevice.poll(Stub.device(), @code) == {:ok, %{code: "a", verifier: "v"}}
    end

    test "gives the Retry-After of a failed poll, at most 60 seconds, else nil" do
      for {header, expected} <- [
            {"7", 7},
            {" 12 ", 12},
            {"3600", 60},
            {"0", nil},
            {"-4", nil},
            {"+5", nil},
            {"5.5", nil},
            {"5 s", nil},
            {"Wed, 21 Oct 2026 07:28:00 GMT", nil},
            {"soon", nil}
          ] do
        Stub.script(poll: 429, retry_after: header)
        assert LoginDevice.poll(Stub.device(), @code) == {:error, "http_429", expected}
      end

      Stub.script(poll: 503)
      assert LoginDevice.poll(Stub.device(), @code) == {:error, "http_503", nil}
    end

    test "fails with the status for any other response, and refuses a grant without a code" do
      stub(&Plug.Conn.send_resp(&1, 500, "{}"))
      assert LoginDevice.poll(Stub.device(), @code) == {:error, "http_500", nil}

      stub(&Plug.Conn.send_resp(&1, 200, ~s({"code_verifier":"v"})))
      assert LoginDevice.poll(Stub.device(), @code) == {:error, "bad_response"}
    end
  end

  describe "exchange/4" do
    @grant %{code: "a", verifier: "v"}

    test "returns the response's object, and refuses a response that is none" do
      stub(&Req.Test.json(&1, %{"access_token" => "x"}))

      assert LoginDevice.exchange(
               "https://auth.example.test/oauth/token",
               Stub.device(),
               @client,
               @grant
             ) ==
               {:ok, %{"access_token" => "x"}}

      stub(&Plug.Conn.send_resp(&1, 200, "[]"))

      assert LoginDevice.exchange(
               "https://auth.example.test/oauth/token",
               Stub.device(),
               @client,
               @grant
             ) ==
               {:error, "bad_response"}

      stub(&Plug.Conn.send_resp(&1, 400, "{}"))

      assert LoginDevice.exchange(
               "https://auth.example.test/oauth/token",
               Stub.device(),
               @client,
               @grant
             ) ==
               {:error, "http_400"}
    end

    test "makes no call to an address the catalogue check refuses" do
      assert LoginDevice.exchange(
               "http://auth.example.test/oauth/token",
               Stub.device(),
               @client,
               @grant
             ) ==
               {:error, "bad_endpoint"}

      assert LoginDevice.exchange(
               "https://auth.example.test/oauth/token",
               %{"redirect_uri" => "http://auth.example.test/cb"},
               @client,
               @grant
             ) == {:error, "bad_endpoint"}
    end
  end
end
