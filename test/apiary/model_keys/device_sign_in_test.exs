defmodule Apiary.ModelKeys.DeviceSignInTest do
  # The device sign-in of a model key: the process of one form (`DeviceSignIn`) and its three
  # calls (`LoginDevice`), against a stub of the provider on a test host. No call leaves the
  # machine, and no token, code or device id is in a message, a status dump or a log line.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Apiary.ModelKeysFixtures
  import Apiary.DeviceSignInStub, only: [eventually: 1, assert_ended: 1]

  alias Apiary.DeviceSignInStub, as: Stub
  alias Apiary.Kinds.Provider
  alias Apiary.ModelKeys.{DeviceSignIn, Login}

  @kind "openai-subscription"

  defp start! do
    ref = make_ref()
    assert {:ok, pid} = DeviceSignIn.start(@kind, ref)
    {pid, ref}
  end

  describe "the catalogue" do
    test "has no device sign-in for the vendored description, which has no oauth_device" do
      refute DeviceSignIn.available?(@kind)
      assert DeviceSignIn.description(@kind) == :error
      assert DeviceSignIn.start(@kind, make_ref()) == {:error, :device_flow_unavailable}
    end

    test "has none for a provider whose keys are no sign-ins, whatever a test puts" do
      Stub.put()
      refute DeviceSignIn.available?("anthropic")
      refute DeviceSignIn.available?("gone")
      refute DeviceSignIn.available?(nil)
    end

    test "takes the addresses and the client id from the entry alone" do
      Stub.put()
      assert {:ok, description} = DeviceSignIn.description(@kind)
      assert description.device == Stub.device()
      assert description.token_url == "https://auth.openai.com/oauth/token"
      assert description.client_id == "app_EMoamEEZ73f0CkXaXp7hrann"
      assert description.account_claim == "/https:~1~1api.openai.com~1auth/chatgpt_account_id"
    end

    test "checks the addresses of an oauth_device when a description is loaded" do
      {:ok, provider} = Apiary.Kinds.Providers.fetch(@kind)

      with_device = fn device ->
        update_in(provider.apis, fn [api] -> [Map.put(api, "oauth_device", device)] end)
      end

      assert Provider.addresses_refused(with_device.(Stub.device())) == []

      refused =
        with_device.(%{Stub.device() | "poll_url" => "http://auth.example.test/token"})
        |> Provider.addresses_refused()

      assert [{"http://auth.example.test/token", {_message, _bindings}}] = refused

      missing =
        with_device.(Map.delete(Stub.device(), "redirect_uri")) |> Provider.addresses_refused()

      assert [{nil, {_message, _bindings}}] = missing
    end
  end

  describe "a sign-in" do
    test "shows the code, polls until the approval, exchanges it and keeps the tokens" do
      tokens = Stub.put(pending: 2)
      {pid, ref} = start!()

      assert_receive {:device_sign_in, ^ref, {:code, shown}}, 1_000
      assert shown.user_code == "7QKD-M4TPX"
      assert shown.verification_url == "https://auth.example.test/device"
      assert %DateTime{} = shown.expires_at
      assert DateTime.diff(shown.expires_at, DateTime.utc_now()) in 850..900

      assert_receive {:device_sign_in, ^ref, :signed_in}, 2_000
      assert Stub.calls(:code) == 1
      assert Stub.calls(:poll) == 3
      assert Stub.calls(:exchange) == 1

      assert {:ok, %Login.Parsed{} = login} = DeviceSignIn.login(pid)
      assert login.account_id == tokens.account_id
      assert Jason.decode!(login.document)["refresh_token"] == tokens.refresh_token
      assert DateTime.diff(login.access_expires_at, DateTime.utc_now(), :day) in 9..10

      # The process keeps the tokens until the form ends it.
      assert {:ok, ^login} = DeviceSignIn.login(pid)
      DeviceSignIn.stop(pid)
      assert_ended(pid)
      assert DeviceSignIn.login(pid) == :error
    end

    test "sends the requests the provider's device sign-in takes" do
      Stub.put()
      {_pid, ref} = start!()
      assert_receive {:device_sign_in, ^ref, :signed_in}, 2_000

      assert_received {:device_call, "/device/usercode", usercode}
      assert Jason.decode!(usercode) == %{"client_id" => "app_EMoamEEZ73f0CkXaXp7hrann"}

      assert_received {:device_call, "/device/token", poll}

      assert Jason.decode!(poll) == %{
               "device_auth_id" => "device-auth-fixture",
               "user_code" => "7QKD-M4TPX"
             }

      assert_received {:device_call, "/oauth/token", exchange}

      assert URI.decode_query(exchange) == %{
               "grant_type" => "authorization_code",
               "client_id" => "app_EMoamEEZ73f0CkXaXp7hrann",
               "code" => "authorization-code-fixture",
               "redirect_uri" => "https://auth.example.test/device/callback",
               "code_verifier" => "verifier-fixture"
             }
    end

    test "ends as off when the provider has no device sign-in for the account (404)" do
      Stub.put(usercode: 404)
      {pid, ref} = start!()

      assert_receive {:device_sign_in, ^ref, {:ended, :off}}, 1_000
      assert_ended(pid)
      assert Stub.calls(:poll) == 0
    end

    test "ends as failed with the status for any other response to the first call" do
      for status <- [400, 403, 429, 500] do
        Stub.put(usercode: status)
        {pid, ref} = start!()
        assert_receive {:device_sign_in, ^ref, {:ended, :failed, ^status}}, 1_000
        assert_ended(pid)
      end
    end

    test "ends as failed after five failed polls in a row" do
      Stub.put(poll: 500)
      {pid, ref} = start!()
      assert_receive {:device_sign_in, ^ref, {:ended, :failed, 500}}, 3_000
      assert_ended(pid)
      assert Stub.calls(:poll) == 5
    end

    test "goes on after fewer than five failed polls in a row" do
      Stub.put(poll: 503, poll_failures: 4)
      {_pid, ref} = start!()
      assert_receive {:device_sign_in, ^ref, :signed_in}, 3_000
      assert Stub.calls(:poll) == 5
    end

    test "counts a pending poll as the end of a run of failures" do
      Stub.put(poll: 500, poll_failures: 3, pending: 5)
      {_pid, ref} = start!()
      assert_receive {:device_sign_in, ^ref, :signed_in}, 3_000
    end

    test "does not count a 429 as a failure, and goes on" do
      Stub.put(poll: 429, poll_failures: 7)
      {_pid, ref} = start!()
      assert_receive {:device_sign_in, ^ref, :signed_in}, 3_000
      assert Stub.calls(:poll) == 8
    end

    test "waits for the Retry-After of a 429 or a 5xx, else for the interval" do
      for status <- [429, 503] do
        Stub.put(poll: status, poll_failures: 1, retry_after: "1")
        {pid, ref} = start!()
        assert_receive {:device_call, "/device/token", _body}, 1_000
        first = System.monotonic_time(:millisecond)
        assert_receive {:device_call, "/device/token", _body}, 3_000
        assert System.monotonic_time(:millisecond) - first >= 900
        assert_receive {:device_sign_in, ^ref, :signed_in}, 2_000
        DeviceSignIn.stop(pid)
        flush_calls()
      end

      Stub.put(poll: 503, poll_failures: 1)
      {_pid, ref} = start!()
      assert_receive {:device_call, "/device/token", _body}, 1_000
      first = System.monotonic_time(:millisecond)
      assert_receive {:device_call, "/device/token", _body}, 1_000
      assert System.monotonic_time(:millisecond) - first < 900
      assert_receive {:device_sign_in, ^ref, :signed_in}, 2_000
    end

    defp flush_calls do
      receive do
        {:device_call, _path, _body} -> flush_calls()
      after
        0 -> :ok
      end
    end

    test "ends as failed with the status when the exchange is refused" do
      Stub.put(exchange: 400)
      {_pid, ref} = start!()
      assert_receive {:device_sign_in, ^ref, {:ended, :failed, 400}}, 2_000
    end

    test "ends as failed with the no-account cause for tokens with no account id" do
      Stub.put(tokens: %{login_tokens(tag: "x") | access_token: "not.a.jwt"})
      {_pid, ref} = start!()
      assert_receive {:device_sign_in, ^ref, {:ended, :failed, :no_account}}, 2_000
    end

    test "ends as failed with an unknown cause for tokens whose account ids differ" do
      other = jwt(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct-other"}})
      Stub.put(tokens: %{login_tokens(tag: "x") | id_token: other})
      {_pid, ref} = start!()
      assert_receive {:device_sign_in, ^ref, {:ended, :failed, :unknown}}, 2_000
    end

    test "ends as failed with an unknown cause for a failure with no status" do
      Stub.put(usercode: 200, code: "")
      {_pid, ref} = start!()
      assert_receive {:device_sign_in, ^ref, {:ended, :failed, :unknown}}, 2_000
    end

    test "makes no exchange call once its owner is gone" do
      Stub.put(hold: true)
      {pid, ref} = start!()
      assert_receive {:device_sign_in, ^ref, {:code, _shown}}, 1_000

      dead = spawn(fn -> :ok end)
      assert_ended(dead)
      :sys.replace_state(pid, fn state -> %{state | owner: dead} end)
      Stub.approve()

      assert_ended(pid)
      assert Stub.calls(:exchange) == 0
    end

    test "ends as failed when a step crashes, and writes no secret to the log" do
      Stub.put(pending: :never)

      log =
        capture_log(fn ->
          {pid, ref} = start!()
          assert_receive {:device_sign_in, ^ref, {:code, _shown}}, 1_000
          :sys.replace_state(pid, fn state -> %{state | expires_at: nil} end)
          assert_receive {:device_sign_in, ^ref, {:ended, :failed, :unknown}}, 1_000
          assert_ended(pid)
        end)

      for secret <- ["device-auth-fixture", "7QKD-M4TPX", "authorization-code-fixture"],
          do: refute(log =~ secret)

      refute log =~ "terminating"
    end

    test "ends as failed when the exchange raises, and writes no grant to the log" do
      Stub.put(hold: true)

      log =
        capture_log(fn ->
          {pid, ref} = start!()
          assert_receive {:device_sign_in, ^ref, {:code, _shown}}, 1_000

          # The exchange reads `description.token_url` with the grant as its argument.
          :sys.replace_state(pid, fn state ->
            %{state | description: Map.delete(state.description, :token_url)}
          end)

          Stub.approve()
          assert_receive {:device_sign_in, ^ref, {:ended, :failed, :unknown}}, 2_000
          assert_ended(pid)
          assert Stub.calls(:exchange) == 0
        end)

      for secret <- [
            "device-auth-fixture",
            "7QKD-M4TPX",
            "authorization-code-fixture",
            "verifier-fixture"
          ],
          do: refute(log =~ secret)

      refute log =~ "terminating"
      refute log =~ "GenServer"
    end

    test "waits for the interval when a Retry-After is shorter than it" do
      Stub.put(poll: 503, poll_failures: 1, retry_after: "1")
      {pid, ref} = start!()

      # Suspended before the first poll at 100 ms, so the poll reads the 5 s interval.
      :sys.suspend(pid)
      :sys.replace_state(pid, fn state -> %{state | interval_ms: 5_000} end)
      :sys.resume(pid)

      assert_receive {:device_call, "/device/token", _body}, 1_000
      first = System.monotonic_time(:millisecond)
      assert_receive {:device_call, "/device/token", _body}, 7_000
      assert System.monotonic_time(:millisecond) - first >= 4_900
      assert_receive {:device_sign_in, ^ref, :signed_in}, 2_000
    end

    test "ends at the 30-minute limit, whatever the code's expiry" do
      Stub.put(pending: :never, expires_at: DateTime.add(DateTime.utc_now(), 7200))
      {pid, ref} = start!()
      assert_receive {:device_sign_in, ^ref, {:code, _shown}}, 1_000

      :sys.replace_state(pid, fn state ->
        %{state | limit: System.monotonic_time(:second) - 1}
      end)

      assert_receive {:device_sign_in, ^ref, {:ended, :expired}}, 1_000
      assert_ended(pid)
    end

    test "ends as expired when the code stops working before the approval" do
      Stub.put(pending: :never, expires_at: DateTime.add(DateTime.utc_now(), 1))
      {pid, ref} = start!()

      assert_receive {:device_sign_in, ^ref, {:code, _shown}}, 1_000
      assert_receive {:device_sign_in, ^ref, {:ended, :expired}}, 3_000
      assert_ended(pid)
      assert DeviceSignIn.login(pid) == :error
    end

    test "makes no call once it is stopped" do
      Stub.put(pending: :never)
      {pid, ref} = start!()

      assert_receive {:device_sign_in, ^ref, {:code, _shown}}, 1_000
      DeviceSignIn.stop(pid)
      assert_ended(pid)

      polls = Stub.calls(:poll)
      Process.sleep(100)
      assert Stub.calls(:poll) == polls
    end

    test "ends when its owner ends" do
      Stub.put(pending: :never)

      pid =
        Task.async(fn ->
          {:ok, pid} = DeviceSignIn.start(@kind, make_ref())
          pid
        end)
        |> Task.await()

      # The task that started it is gone, and so is the sign-in.
      assert_ended(pid)
    end

    test "gives the tokens to its owner alone" do
      Stub.put()
      {pid, ref} = start!()
      assert_receive {:device_sign_in, ^ref, :signed_in}, 2_000

      other = Task.async(fn -> DeviceSignIn.login(pid) end)
      assert Task.await(other) == :error
      assert {:ok, _login} = DeviceSignIn.login(pid)
    end

    test "makes no call to an address that is not https, and ends as failed" do
      DeviceSignIn.put_test_device(@kind, %{
        Stub.device()
        | "usercode_url" => "http://auth.example.test/x"
      })

      Stub.script()
      {_pid, ref} = start!()

      assert_receive {:device_sign_in, ^ref, {:ended, :failed, :unknown}}, 1_000
      assert Stub.calls(:code) == 0
    end

    test "shows no token, code or device id in a status dump, a message or a log line" do
      tokens = Stub.put(pending: 1)
      secrets = secrets_of(tokens)

      log =
        capture_log(fn ->
          {pid, ref} = start!()
          assert_receive {:device_sign_in, ^ref, {:code, shown} = code_event}, 1_000
          assert shown.user_code == "7QKD-M4TPX"
          dump = inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)
          assert_receive {:device_sign_in, ^ref, :signed_in = signed_event}, 2_000
          events = inspect([code_event, signed_event], limit: :infinity)
          for secret <- secrets, do: refute(events =~ secret)

          dump =
            dump <> inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)

          {:ok, login} = DeviceSignIn.login(pid)
          dump = dump <> inspect(login, limit: :infinity)
          for secret <- secrets, do: refute(dump =~ secret)

          for secret <- secrets, do: refute(messages() =~ secret)
        end)

      for secret <- secrets, do: refute(log =~ secret)
    end

    test "shows no secret of an error response in a message or a log line" do
      tokens = Stub.put(exchange: 400, error_body: "secret-in-the-error-body")
      secrets = ["secret-in-the-error-body" | secrets_of(tokens)]

      log =
        capture_log(fn ->
          {pid, ref} = start!()
          assert_receive {:device_sign_in, ^ref, {:ended, :failed, 400}}, 2_000
          assert_ended(pid)
          for secret <- secrets, do: refute(messages() =~ secret)
        end)

      for secret <- secrets, do: refute(log =~ secret)

      Stub.put(poll: 500, error_body: "secret-in-the-error-body")

      log =
        capture_log(fn ->
          {pid, ref} = start!()
          assert_receive {:device_sign_in, ^ref, {:ended, :failed, 500}}, 3_000
          assert_ended(pid)
          for secret <- secrets, do: refute(messages() =~ secret)
        end)

      for secret <- secrets, do: refute(log =~ secret)
    end

    defp secrets_of(tokens),
      do: [
        tokens.access_token,
        tokens.refresh_token,
        tokens.id_token,
        "device-auth-fixture",
        "authorization-code-fixture",
        "verifier-fixture"
      ]

    # The messages the sign-in sent to the test process, as text. The messages of the stub,
    # which has the requests it got, are not the sign-in's.
    defp messages do
      {:messages, messages} = Process.info(self(), :messages)

      messages
      |> Enum.filter(&match?({:device_sign_in, _ref, _event}, &1))
      |> inspect(limit: :infinity, printable_limit: :infinity)
    end

    test "keeps an unrelated message from ending it" do
      Stub.put(pending: :never)
      {pid, ref} = start!()
      assert_receive {:device_sign_in, ^ref, {:code, _shown}}, 1_000
      send(pid, :anything)
      eventually(fn -> assert Process.alive?(pid) end)
      DeviceSignIn.stop(pid)
    end
  end
end
