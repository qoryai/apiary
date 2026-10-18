defmodule ApiaryWeb.LiveSocketTest do
  # The bounds of the "/live" socket: a websocket frame at 4 MiB, and a fragmented message
  # the same, merged into the endpoint's `http:` beside the environment's, and put into an
  # `https:` at boot when there is one.
  use ExUnit.Case, async: true

  alias ApiaryWeb.Endpoint

  # The listeners Bandit's adapter makes of a configuration: their child specs, built
  # without starting anything.
  defp listeners(config) do
    for %{id: {Endpoint, scheme}, start: {Bandit, :start_link, [opts]}} <-
          Bandit.PhoenixAdapter.child_specs(Endpoint, [otp_app: :apiary] ++ config),
        do: {scheme, opts}
  end

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

  test "an `https:` gets the same bound, and so does the listener made of it" do
    https = [port: 4443, keyfile: "priv/cert/key.pem", certfile: "priv/cert/cert.pem"]
    config = Endpoint.bound_https(http: [port: 4002], https: https)

    assert config[:https][:websocket_options] == [max_fragmented_message_size: 4_194_304]
    assert Keyword.delete(config[:https], :websocket_options) == https
    assert config[:http] == [port: 4002]

    assert [http: _, https: opts] = listeners(config)
    assert opts[:websocket_options][:max_fragmented_message_size] == 4_194_304

    # Beside the websocket options it names, in a list that is not only keywords.
    config =
      Endpoint.bound_https(https: [:inet6, port: 4443, websocket_options: [compress: false]])

    assert config[:https] == [
             :inet6,
             port: 4443,
             websocket_options: [max_fragmented_message_size: 4_194_304, compress: false]
           ]

    # A bound the `https:` names is kept.
    https = [port: 4443, websocket_options: [max_fragmented_message_size: 1_048_576]]
    assert Endpoint.bound_https(https: https) == [https: https]
  end

  test "without an `https:`, none is added, nor a listener" do
    config = [http: [port: 4002]]

    for config <- [config, [https: nil] ++ config, [https: false] ++ config] do
      assert Endpoint.bound_https(config) == config
      assert [http: _] = listeners(config)
    end

    # As the app booted.
    env = Application.get_env(:apiary, Endpoint)
    refute Keyword.has_key?(env, :https)
    assert Endpoint.config(:https) == false
    assert [http: _] = listeners(env)
  end
end
