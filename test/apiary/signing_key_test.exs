defmodule Apiary.SigningKeyTest do
  # Not async: the seed is the application's configuration, set for a test and put back
  # after it.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Apiary.Contract.Ed25519
  alias Apiary.SigningKey

  # The runner contract's fixture signing keys, current and next, and their known answers
  # (runner contracts/runner/v1/fixtures/known-answers/keys.json, at the commit
  # .runner-contract-ref names): the seeds are the bytes 65 to 96 and 161 to 192.
  @fixture_seed :binary.list_to_bin(Enum.to_list(65..96))
  @fixture_public_key "rcFAEfgtHFbZVqpPnXPYhYNhpgYEhSXg0Ixjjcdd2Mc"
  @fixture_fingerprint "uoES-kuj1vk0sq0qoGlmAg"
  @next_seed :binary.list_to_bin(Enum.to_list(161..192))
  @next_public_key "C0eCPnEJXdWb54rCccV27zifh7ZFYasHz5pOvNAtIEE"
  @next_fingerprint "52vzzF--Ic7qH_eZWi5K2A"

  # Every 32-byte value the contract publishes: the fixture access key's seed, the sealed
  # fixture's ephemeral key, the signing keys', and the seed of the second fixture access key.
  @published [1..32, 33..64, 65..96, 161..192, 193..224]
             |> Enum.map(&:binary.list_to_bin(Enum.to_list(&1)))

  # The request signature of the GET of discovery under the fixture access key
  # (known-answers/signatures.json), line 3 of the answers below.
  @request_signature "H9XeK0R-KWGvQNITRP01Fh9_62ATGKd7rTgehaIPjcYYM374LrKzswcmQRYO0m-2UHx6NJJxWT3rk0HL4sD_CQ"

  setup do
    previous = Application.get_env(:apiary, SigningKey)
    on_exit(fn -> Application.put_env(:apiary, SigningKey, previous) end)
  end

  defp configure(seed), do: Application.put_env(:apiary, SigningKey, seed: seed)

  # Every form a seed could be written in, none of which may appear in a message, an
  # inspect or a log.
  defp forms(seed) do
    [
      seed,
      Base.encode64(seed),
      Base.encode64(seed, padding: false),
      Base.url_encode64(seed, padding: false),
      Base.encode16(seed, case: :lower),
      Base.encode16(seed),
      inspect(seed),
      inspect(seed, binaries: :as_binaries),
      inspect(seed, binaries: :as_binaries, base: :hex)
    ]
  end

  defp refute_seed(text, seed) do
    for form <- forms(seed), do: refute(text =~ form)
  end

  describe "the contract's known answers" do
    test "the fixture signing keys' public keys and fingerprints" do
      key = SigningKey.new(@fixture_seed)
      assert Ed25519.encode(SigningKey.public_key(key)) == @fixture_public_key
      assert SigningKey.fingerprint(key) == @fixture_fingerprint

      next = SigningKey.new(@next_seed)
      assert Ed25519.encode(SigningKey.public_key(next)) == @next_public_key
      assert SigningKey.fingerprint(next) == @next_fingerprint
    end

    test "the signed answers to the GET of discovery, 200 and 404" do
      key = SigningKey.new(@fixture_seed)

      ok =
        Enum.join(
          [
            "qory-answer-ed25519-v1",
            "200",
            @request_signature,
            "b6813bc64b11564b8a58b39b8d7ccdf947bcadcde5c1744dd01894f941a52862",
            "sha256=b6813bc64b11564b8a58b39b8d7ccdf947bcadcde5c1744dd01894f941a52862",
            ""
          ],
          "\n"
        )

      not_found =
        Enum.join(
          [
            "qory-answer-ed25519-v1",
            "404",
            @request_signature,
            Base.encode16(:crypto.hash(:sha256, ""), case: :lower),
            "",
            ""
          ],
          "\n"
        )

      assert byte_size(ok) == 251
      assert byte_size(not_found) == 180

      assert Ed25519.encode(SigningKey.sign(key, ok)) ==
               "KR8RzAb1z5MnEj2SPYFrghfXqVdU7Da2Yu0qU1-VQhmuObVUiKLywh8FoTawEfg9u0VgOgFQJhutD3-w4a55Bg"

      assert Ed25519.encode(SigningKey.sign(key, not_found)) ==
               "wtXEpqIYCRAH0I9P0wd1DxJxkury0OE566ADTu3bH2GWUP4-TAkNl3a5oKGP6ZVWsP8oPL-yJHuaOaxbNPU_Dg"
    end

    test "apiary_public_key is the list the fixtures write, one key and two in a rotation" do
      key = SigningKey.new(@fixture_seed)
      next = SigningKey.new(@next_seed)

      # As known-answers/discovery.json and enrolment/answer.json write it.
      assert Jason.encode!(SigningKey.apiary_public_key([key])) ==
               ~s([{"alg":"ed25519","public_key":"#{@fixture_public_key}"}])

      # As enrolment/refusal-key-limit-rotation.json writes it: the current key, then
      # the next.
      assert Jason.encode!(SigningKey.apiary_public_key([key, next])) ==
               ~s([{"alg":"ed25519","public_key":"#{@fixture_public_key}"},) <>
                 ~s({"alg":"ed25519","public_key":"#{@next_public_key}"}])
    end
  end

  describe "the instance's key" do
    test "is the configured seed's, signs what verifies under it, and lists it alone" do
      seed = Keyword.fetch!(Application.get_env(:apiary, SigningKey), :seed)
      key = SigningKey.current()

      assert SigningKey.public_key() == SigningKey.public_key(SigningKey.new(seed))
      assert Ed25519.check_public_key(SigningKey.public_key()) == :ok
      assert SigningKey.fingerprint() == Ed25519.fingerprint(SigningKey.public_key())
      assert String.length(SigningKey.fingerprint()) == 22

      message = "qory-answer-ed25519-v1\n200\nsig\nbody\n\n"
      signature = SigningKey.sign(message)
      assert byte_size(signature) == 64
      assert Ed25519.verify(message, signature, SigningKey.public_key())
      refute Ed25519.verify(message <> "x", signature, SigningKey.public_key())
      assert SigningKey.sign(key, message) == signature

      assert SigningKey.apiary_public_key() == [
               %{"alg" => "ed25519", "public_key" => Ed25519.encode(SigningKey.public_key())}
             ]

      assert SigningKey.boot!() == :ok
    end

    test "is no key derived from APIARY_ENCRYPTION_SECRET" do
      refute Map.has_key?(Apiary.KeyDerivation.purposes(), :envelope_signing)

      for {purpose, _info} <- Apiary.KeyDerivation.purposes() do
        {_id, derived} = Apiary.KeyDerivation.key(purpose)
        refute SigningKey.public_key() == SigningKey.public_key(SigningKey.new(derived))
      end
    end

    test "changes with the seed and nothing else" do
      configure(String.duplicate("a", 32))
      first = SigningKey.public_key()
      configure(String.duplicate("b", 32))
      refute SigningKey.public_key() == first
    end
  end

  describe "a seed refused" do
    test "check_seed/1 refuses every value the contract publishes, and the wrong lengths" do
      for seed <- @published, do: assert(SigningKey.check_seed(seed) == {:error, :fixture})

      for seed <- [nil, "", String.duplicate("a", 31), String.duplicate("a", 33), :seed],
          do: assert(SigningKey.check_seed(seed) == {:error, :length})

      assert SigningKey.check_seed(String.duplicate("a", 32)) == :ok
    end

    test "a published seed stops the boot and every use, naming the variable, never the value" do
      for seed <- @published do
        configure(seed)

        log =
          capture_log(fn ->
            for fun <- [&SigningKey.boot!/0, &SigningKey.current/0, &SigningKey.public_key/0] do
              error = assert_raise ArgumentError, fun
              assert error.message =~ "APIARY_SIGNING_SECRET"
              assert error.message =~ "fixtures"
              refute_seed(error.message, seed)
            end

            assert_raise ArgumentError, fn -> SigningKey.sign("message") end
          end)

        refute_seed(log, seed)
      end
    end

    test "a missing seed, or one not 32 bytes, stops the boot, naming the variable, never the value" do
      seed = String.duplicate("z", 31)

      for config <- [[], [seed: nil], [seed: seed], [seed: seed <> "zz"]] do
        Application.put_env(:apiary, SigningKey, config)
        error = assert_raise ArgumentError, &SigningKey.boot!/0
        assert error.message =~ "APIARY_SIGNING_SECRET is missing, or not 32 bytes"
        refute_seed(error.message, seed)
      end

      Application.delete_env(:apiary, SigningKey)
      assert_raise ArgumentError, ~r/APIARY_SIGNING_SECRET/, &SigningKey.current/0
    end

    test "new/1 refuses a seed of the wrong length without showing it" do
      seed = String.duplicate("z", 31)
      error = assert_raise ArgumentError, fn -> SigningKey.new(seed) end
      assert error.message =~ "APIARY_SIGNING_SECRET"
      refute_seed(error.message, seed)
    end
  end

  describe "the seed is never shown" do
    test "inspect shows the fingerprint, whatever holds the key" do
      seed = String.duplicate("s", 32)
      key = SigningKey.new(seed)
      fingerprint = SigningKey.fingerprint(key)

      for shown <- [
            inspect(key),
            inspect([key]),
            inspect(%{key: key}),
            inspect({:ok, key}, pretty: true, limit: :infinity),
            inspect(key, structs: true, binaries: :as_binaries)
          ] do
        assert shown =~ "#Apiary.SigningKey<fingerprint: \"#{fingerprint}\">"
        refute_seed(shown, seed)
      end

      # Nor of a key that is not whole: no fallback to its fields.
      broken = %{key | public_key: nil}
      assert inspect(broken) == "#Apiary.SigningKey<>"
      refute_seed(inspect(broken), seed)
    end

    test "nor among the arguments of an error, nor in a crash's log" do
      seed = String.duplicate("s", 32)
      key = SigningKey.new(seed)

      # Not a message, as the compiler cannot tell before the test runs.
      not_a_message = Application.get_env(:apiary, :no_such_setting, 42)

      {error, stacktrace} =
        try do
          SigningKey.sign(key, not_a_message)
        rescue
          error -> {error, __STACKTRACE__}
        end

      assert %FunctionClauseError{} = error
      {blamed, _stacktrace} = Exception.blame(:error, error, stacktrace)
      formatted = Exception.format(:error, blamed, stacktrace)
      assert formatted =~ "#Apiary.SigningKey<fingerprint:"
      refute_seed(formatted, seed)

      log =
        capture_log(fn ->
          # A task logs its crash itself before it exits, so the report is in the log by
          # the time it is down.
          {:ok, pid} = Task.start(fn -> SigningKey.sign(key, not_a_message) end)
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
        end)

      # The crash is in the log, with the key among its arguments, and the seed is not.
      assert log =~ "FunctionClauseError"
      assert log =~ "#Apiary.SigningKey<fingerprint:"
      refute_seed(log, seed)
    end
  end
end
