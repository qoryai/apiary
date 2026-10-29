defmodule Apiary.Adapters.CallTrustTest do
  # The certificate authorities an adapter call trusts (`Apiary.Adapters.CallTrust`):
  # with `SSL_CERT_FILE` unset, the call's options are those Mint fills with the operating
  # system's; with it set, the operating system's and the file's, the peer verified and
  # the host checked either way; a file that cannot be read or has no certificate stops
  # the boot. The certificates are made here (`:public_key.pkix_test_data/1`), and a call
  # goes to a TLS listener on 127.0.0.1 that this module starts on a free port.
  #
  # Not async: the certificates `boot!/0` keeps are the application's environment.
  use Apiary.DataCase, async: false

  import Apiary.NodesFixtures

  alias Apiary.Adapters.{CallFailure, Calls, CallTrust}
  alias Apiary.Contract.{Ed25519, SignedMessage}

  @moduletag :capture_log
  @moduletag :tmp_dir

  @ok ~s({"version":1,"revision":1,"results":[]})
  @fast [attempt: 2_000, total: 5_000, retry_wait: {1, 2}]

  setup do
    setting = Application.get_env(:apiary, :ssl_cert_file_setting)
    kept = Application.get_env(:apiary, CallTrust)

    on_exit(fn ->
      restore(:ssl_cert_file_setting, setting)
      restore(CallTrust, kept)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:apiary, key)
  defp restore(key, value), do: Application.put_env(:apiary, key, value)

  # A certificate authority and a server certificate it signs for `host`, P-256 keys and
  # SHA-256 signatures, which TLS 1.2 and 1.3 accept. The client's `cacerts` start with
  # the server chain's root.
  defp chain(host) do
    san = {:Extension, {2, 5, 29, 17}, false, [{:dNSName, String.to_charlist(host)}]}
    key = [key: {:namedCurve, :secp256r1}, digest: :sha256]

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{root: key, intermediates: [], peer: key ++ [extensions: [san]]},
        client_chain: %{root: key, intermediates: [], peer: key}
      })

    %{
      authorities: [hd(data[:client_config][:cacerts])],
      cert: data[:server_config][:cert],
      key: data[:server_config][:key]
    }
  end

  defp pem(ders),
    do: :public_key.pem_encode(for der <- ders, do: {:Certificate, der, :not_encrypted})

  defp write(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  describe "load!/1" do
    test "is every certificate of the PEM file, in order", %{tmp_dir: dir} do
      %{authorities: [a]} = chain("tracker.localhost")
      %{authorities: [b]} = chain("tracker.localhost")
      path = write(dir, "ca.pem", pem([a, b]))

      assert CallTrust.load!(path) == [a, b]
    end

    test "leaves out the blocks that are not certificates", %{tmp_dir: dir} do
      %{authorities: [a], key: {type, der}} = chain("tracker.localhost")
      key = :public_key.pem_encode([{type, der, :not_encrypted}])
      path = write(dir, "ca.pem", key <> pem([a]))

      assert CallTrust.load!(path) == [a]
    end

    test "raises with the fix first for a missing file, one with no certificate, and a broken one",
         %{tmp_dir: dir} do
      %{key: {type, der}} = chain("tracker.localhost")
      missing = Path.join(dir, "missing.pem")
      empty = write(dir, "empty.pem", "")
      text = write(dir, "text.pem", "not a certificate\n")
      key = write(dir, "key.pem", :public_key.pem_encode([{type, der, :not_encrypted}]))

      broken =
        write(dir, "broken.pem", pem([:binary.copy("x", 64)]))

      for {path, cause} <- [
            {missing, "Reading #{missing} failed: no such file or directory."},
            {dir, "Reading #{dir} failed: illegal operation on a directory."},
            {empty, "#{empty} contains no PEM certificate."},
            {text, "#{text} contains no PEM certificate."},
            {key, "#{key} contains no PEM certificate."},
            {broken, "#{broken} contains a PEM block that is not a valid X.509 certificate."}
          ] do
        error = assert_raise ArgumentError, fn -> CallTrust.load!(path) end

        assert error.message ==
                 """
                 Set SSL_CERT_FILE to a PEM file of CA certificates, or unset it. #{cause}
                 Adapter calls trust the operating system's certificate authorities and every certificate in that file.
                 """
      end
    end
  end

  describe "transport_opts/1" do
    test "is nothing without certificates, so Mint takes the operating system's" do
      assert CallTrust.transport_opts([]) == []
    end

    test "is the operating system's certificates, then the file's, and nothing else" do
      %{authorities: [a]} = chain("tracker.localhost")
      system = for {:cert, der, _otp} <- :public_key.cacerts_get(), do: der

      assert CallTrust.transport_opts([a]) == [cacerts: system ++ [a]]
    end
  end

  describe "boot!/0" do
    @describetag needs: :factory

    test "keeps no certificate when SSL_CERT_FILE is unset or blank" do
      for setting <- [nil, ""] do
        Application.put_env(:apiary, :ssl_cert_file_setting, setting)
        assert CallTrust.boot!() == :ok
        assert Application.get_env(:apiary, CallTrust) == []
        assert CallTrust.transport_opts() == []
      end
    end

    test "keeps the file's certificates", %{tmp_dir: dir} do
      %{authorities: [a]} = chain("tracker.localhost")
      Application.put_env(:apiary, :ssl_cert_file_setting, write(dir, "ca.pem", pem([a])))

      assert CallTrust.boot!() == :ok
      assert Application.get_env(:apiary, CallTrust) == [a]
      assert List.last(CallTrust.transport_opts()[:cacerts]) == a
    end

    test "stops the boot for a file that cannot be read or has no certificate", %{tmp_dir: dir} do
      missing = Path.join(dir, "missing.pem")
      Application.put_env(:apiary, :ssl_cert_file_setting, missing)

      assert_raise ArgumentError,
                   ~r/\ASet SSL_CERT_FILE to a PEM file of CA certificates, or unset it\. Reading /,
                   &CallTrust.boot!/0
    end
  end

  describe "a call" do
    @describetag needs: :factory

    setup do
      %{adapter: adapter, pair: pair} = connectable_adapter_fixture()
      %{adapter: adapter, host: adapter.name <> ".localhost", seed: pair.secret}
    end

    # The adapter at `port` on 127.0.0.1, its host `host`; the call goes there with no stub.
    defp at(adapter, host, port, opts \\ []) do
      adapter = %{adapter | call_url: "https://#{host}:#{port}/calls/", call_instance_id: "i-1"}

      Calls.call(
        adapter,
        "resolve",
        [{"addresses", ["https://a.example/x"]}],
        @fast ++
          [
            resolver: fn ^host -> {:ok, [{127, 0, 0, 1}]} end,
            req_options: opts
          ]
      )
    end

    # The options Req receives, without a connection.
    defp options_of(adapter, host) do
      test = self()

      seen = fn request ->
        send(test, {:connect_options, request.options[:connect_options]})
        {request, Req.Response.new(status: 503)}
      end

      at(adapter, host, 8443, adapter: seen)
      assert_received {:connect_options, options}
      options
    end

    test "without SSL_CERT_FILE sets the host and the timeout alone, as before",
         %{adapter: adapter, host: host} do
      Application.put_env(:apiary, CallTrust, [])
      assert options_of(adapter, host) == [hostname: host, timeout: 2_000]
    end

    test "with SSL_CERT_FILE adds the operating system's certificates and the file's",
         %{adapter: adapter, host: host} do
      %{authorities: [a]} = chain(host)
      Application.put_env(:apiary, CallTrust, [a])

      assert [hostname: ^host, timeout: 2_000, transport_opts: [cacerts: cacerts]] =
               options_of(adapter, host)

      assert List.last(cacerts) == a
    end

    test "reaches an adapter on 127.0.0.1 whose certificate the file's authority signs",
         %{adapter: adapter, host: host, seed: seed} do
      %{authorities: authorities} = keys = chain(host)
      port = listen(keys, seed)

      Application.put_env(:apiary, CallTrust, authorities)

      assert at(adapter, host, port) ==
               {:ok, %{"version" => 1, "revision" => 1, "results" => []}}
    end

    test "is :unreachable when no authority it trusts signs the certificate",
         %{adapter: adapter, host: host, seed: seed} do
      port = listen(chain(host), seed)
      %{authorities: other} = chain(host)

      for trusted <- [[], other] do
        Application.put_env(:apiary, CallTrust, trusted)

        assert {:error, %CallFailure{cause: :unreachable}} = at(adapter, host, port)
      end
    end

    test "is :unreachable when the certificate is for another host",
         %{adapter: adapter, host: host, seed: seed} do
      %{authorities: authorities} = keys = chain("other.localhost")
      port = listen(keys, seed)

      Application.put_env(:apiary, CallTrust, authorities)

      assert {:error, %CallFailure{cause: :unreachable}} = at(adapter, host, port)
    end
  end

  # A TLS listener on 127.0.0.1, on a free port, that answers each call as the adapter,
  # signed under `seed`; stopped with the test.
  defp listen(%{cert: cert, key: key}, seed) do
    pid =
      start_supervised!(
        {Bandit,
         plug: {__MODULE__.Adapter, seed},
         scheme: :https,
         ip: :loopback,
         port: 0,
         startup_log: false,
         thousand_island_options: [transport_options: [cert: cert, key: key]]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defmodule Adapter do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(seed), do: seed

    @impl true
    def call(conn, seed) do
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      [call_signature] = Plug.Conn.get_req_header(conn, "x-qory-signature-ed25519")
      body = ~s({"version":1,"revision":1,"results":[]})
      message = SignedMessage.call_answer(200, call_signature, body)
      signature = Ed25519.encode(:crypto.sign(:eddsa, :none, message, [seed, :ed25519]))

      conn
      |> Plug.Conn.put_resp_header("x-qory-signature-ed25519", signature)
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end
  end
end
