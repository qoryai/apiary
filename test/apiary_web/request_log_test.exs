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

      assert RequestLog.redact_path("/users/password/#{@token}") == "/users/password/:token"
      assert RequestLog.redact_path("/setup/#{@token}") == "/setup/:code"

      assert RequestLog.redact_path("/instance/mail/confirm/#{@token}") ==
               "/instance/mail/confirm/:token"
    end

    test "a trailing or doubled slash does not get a token through" do
      for path <- [
            "/invitations/#{@token}/",
            "//invitations//#{@token}",
            "/users/log-in/#{@token}/",
            "//users/password//#{@token}/",
            "/invitations/#{@token}/continue/",
            "/setup/#{@token}/",
            "//setup//#{@token}",
            "/instance//mail/confirm/#{@token}/"
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
            "/setup",
            "/.well-known/qory-configuration",
            "/acme/members/7b1c/remove",
            "/instance/mail"
          ] do
        assert RequestLog.redact_path(path) == path
      end
    end
  end

  @frame "/acme/main/work/7/artifacts/av_1jvd3522b8vqehhm/mockup"
  @frame_token "SFMyNTY.g2gDdAAAAAN3AXVtAAAAJGE.Xy-9_aB"

  test "replaces the token of a mockup frame's path, and keeps the rest" do
    for path <- ["#{@frame}/#{@frame_token}/home.html", "/#{@frame}//#{@frame_token}/home.html/"] do
      assert RequestLog.redact_path(path) == "#{@frame}/:token/home.html"
    end

    # A path that ends at the token: its last segment is read as a token.
    assert RequestLog.redact_path("#{@frame}/#{@frame_token}") == "#{@frame}/:token"
    assert RequestLog.redact_path("#{@frame}/home.html") == "#{@frame}/:token"
    assert RequestLog.redact_path("#{@frame}") == "#{@frame}"
  end

  test "the logged request line of a mockup frame has no token" do
    conn = Plug.Test.conn(:get, "#{@frame}/#{@frame_token}/home.html") |> Plug.Conn.resp(200, "")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        RequestLog.handle_event(
          [:phoenix, :endpoint, :stop],
          %{duration: System.convert_time_unit(1, :millisecond, :native)},
          %{conn: conn},
          :error
        )
      end)

    assert log =~ "GET #{@frame}/:token/home.html"
    refute log =~ @frame_token
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
