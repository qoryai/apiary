defmodule ApiaryWeb.RequestLogTest do
  use ExUnit.Case, async: true

  alias ApiaryWeb.RequestLog

  @token "kT2pQ9x_0aVb-secret-token"

  describe "redact_path/1" do
    test "replaces the token of every token-bearing route" do
      assert RequestLog.redact_path("/invitations/#{@token}") == "/invitations/:token"

      assert RequestLog.redact_path("/invitations/#{@token}/continue") ==
               "/invitations/:token/continue"

      assert RequestLog.redact_path("/users/log-in/#{@token}") == "/users/log-in/:token"

      assert RequestLog.redact_path("/users/settings/confirm-email/#{@token}") ==
               "/users/settings/confirm-email/:token"
    end

    test "a trailing or doubled slash does not get a token through" do
      for path <- [
            "/invitations/#{@token}/",
            "//invitations//#{@token}",
            "/users/log-in/#{@token}/",
            "/invitations/#{@token}/continue/"
          ] do
        refute RequestLog.redact_path(path) =~ @token
      end
    end

    test "leaves every other path as it is" do
      for path <- [
            "/",
            "/health",
            "/acme/main/keys",
            "/users/log-in",
            "/users/settings",
            "/invitations",
            "/.well-known/qory-configuration",
            "/acme/members/7b1c/remove"
          ] do
        assert RequestLog.redact_path(path) == path
      end
    end
  end

  test "the logged request line carries the redacted path" do
    conn = Plug.Test.conn(:get, "/users/log-in/#{@token}") |> Plug.Conn.resp(200, "")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        RequestLog.handle_event(
          [:phoenix, :endpoint, :stop],
          %{duration: System.convert_time_unit(1, :millisecond, :native)},
          %{conn: conn},
          :error
        )
      end)

    assert log =~ "GET /users/log-in/:token"
    refute log =~ @token
  end
end
