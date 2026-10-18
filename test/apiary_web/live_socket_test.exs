defmodule ApiaryWeb.LiveSocketTest do
  # The bounds of the "/live" socket: a websocket frame at 4 MiB, and a fragmented message
  # the same, merged into the endpoint's `http:` beside the environment's.
  use ExUnit.Case, async: true

  test "a websocket frame of the \"/live\" socket is bounded at 4 MiB" do
    assert {"/live", Phoenix.LiveView.Socket, opts} =
             List.keyfind(ApiaryWeb.Endpoint.__sockets__(), "/live", 0)

    assert opts[:websocket][:max_frame_size] == 4_194_304
  end

  test "a fragmented message is bounded the same, beside the environment's address and port" do
    http = ApiaryWeb.Endpoint.config(:http)

    assert http[:websocket_options][:max_fragmented_message_size] == 4_194_304
    assert http[:ip] == {127, 0, 0, 1}
    assert http[:port] == 4002
  end
end
