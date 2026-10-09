defmodule Apiary.IntegrityTest do
  # Not async: the secret is the application's configuration, set for a test and put
  # back after it.
  use ExUnit.Case, async: false

  alias Apiary.{Integrity, KeyDerivation}

  @secret :binary.list_to_bin(Enum.to_list(0..31))
  @fields [id: "ak_0123456789abcdef", revoked: false, note: nil]

  setup do
    previous = Application.get_env(:apiary, KeyDerivation)
    Application.put_env(:apiary, KeyDerivation, secret: @secret)
    on_exit(fn -> Application.put_env(:apiary, KeyDerivation, previous) end)
  end

  test "the code of a fixed row is the known answer" do
    # Computed outside the application, with Python's hmac, from the encoding the module
    # documents and the integrity key of the secret 00 01 … 1f.
    assert {"00c237515a3185d8", code} = Integrity.code("example", 1, @fields)

    assert Base.encode16(code, case: :lower) ==
             "2bea58957fa9b230709ed5aa97e2319b747296381966b4fa8f53ae0b43acc05c"
  end

  test "the encoding is the documented one" do
    assert Integrity.encode("example", 1, @fields) ==
             IO.iodata_to_binary([
               <<19::16>>,
               "apiary-integrity-v1",
               <<7::16>>,
               "example",
               <<1::16, 3::16>>,
               [<<2::16>>, "id", <<1, 19::32>>, "ak_0123456789abcdef"],
               [<<7::16>>, "revoked", <<3, 1::32>>, "0"],
               [<<4::16>>, "note", <<0, 0::32>>]
             ])
  end

  test "a code verifies for the same fields, and only for them" do
    {key_id, code} = Integrity.code("access_key", 1, @fields)
    assert Integrity.verify("access_key", 1, @fields, key_id, code) == :ok

    for {kind, version, fields} <- [
          {"other_kind", 1, @fields},
          {"access_key", 2, @fields},
          {"access_key", 1, Keyword.put(@fields, :revoked, true)},
          {"access_key", 1, Keyword.put(@fields, :id, "ak_0123456789abcdeg")},
          {"access_key", 1, Keyword.put(@fields, :note, "")},
          {"access_key", 1, Enum.reverse(@fields)},
          {"access_key", 1, Keyword.delete(@fields, :note)},
          {"access_key", 1, @fields ++ [extra: nil]},
          {"access_key", 1, [ID: "ak_0123456789abcdef", revoked: false, note: nil]}
        ] do
      assert Integrity.verify(kind, version, fields, key_id, code) == {:error, :mismatch},
             "#{inspect({kind, version, fields})} verified"
    end
  end

  test "a tampered code, a cut one and a missing one do not verify" do
    {key_id, <<first, rest::binary>> = code} = Integrity.code("access_key", 1, @fields)

    for bad <- [<<Bitwise.bxor(first, 1), rest::binary>>, binary_part(code, 0, 31), "", nil] do
      assert Integrity.verify("access_key", 1, @fields, key_id, bad) == {:error, :mismatch}
    end

    assert Integrity.verify("access_key", 1, @fields, nil, code) == {:error, :mismatch}
  end

  test "a code made under a key the instance no longer holds is told apart" do
    {key_id, code} = Integrity.code("access_key", 1, @fields)
    Application.put_env(:apiary, KeyDerivation, secret: :binary.copy(<<9>>, 32))

    assert Integrity.verify("access_key", 1, @fields, key_id, code) == {:error, :unknown_key}

    {new_id, _code} = Integrity.code("access_key", 1, @fields)
    assert Integrity.verify("access_key", 1, @fields, new_id, code) == {:error, :mismatch}
  end

  test "values of different types that look alike encode apart" do
    pairs = [
      {nil, ""},
      {1, "1"},
      {true, "1"},
      {false, 0},
      {["a", "b"], "ab"},
      {["ab"], ["a", "b"]},
      {[], nil},
      {:ok, "ok"},
      {~U[2026-10-04 12:00:00Z], 1_791_115_200_000_000}
    ]

    for {a, b} <- pairs do
      refute Integrity.encode("k", 1, x: a) == Integrity.encode("k", 1, x: b),
             "#{inspect(a)} and #{inspect(b)} encode alike"
    end

    # Field boundaries cannot move: the length prefixes keep "ab" + "c" from "a" + "bc".
    refute Integrity.encode("k", 1, a: "ab", b: "c") == Integrity.encode("k", 1, a: "a", b: "bc")
  end

  test "an instant codes alike whatever its precision" do
    at = ~U[2026-10-04 12:00:00.000000Z]

    assert Integrity.encode("k", 1, at: at) ==
             Integrity.encode("k", 1, at: ~U[2026-10-04 12:00:00Z])

    refute Integrity.encode("k", 1, at: at) ==
             Integrity.encode("k", 1, at: DateTime.add(at, 1, :microsecond))
  end

  test "a caller's mistakes raise, without the value in the message" do
    assert_raise ArgumentError, ~r/named twice/, fn ->
      Integrity.encode("k", 1, a: 1, a: 2)
    end

    assert_raise ArgumentError, fn -> Integrity.encode("k", -1, []) end
    assert_raise ArgumentError, fn -> Integrity.encode("k", 65_536, []) end
    assert_raise ArgumentError, fn -> Integrity.encode(:k, 1, []) end
    assert_raise ArgumentError, fn -> Integrity.encode(String.duplicate("k", 65_536), 1, []) end

    error = assert_raise ArgumentError, fn -> Integrity.encode("k", 1, a: %{secret: "s3cr3t"}) end
    refute error.message =~ "s3cr3t"
    assert_raise ArgumentError, fn -> Integrity.encode("k", 1, a: 1.5) end
    assert_raise ArgumentError, fn -> Integrity.verify("k", 1, [a: {1}], "x", "y") end
  end

  test "lp/1 is a big-endian u16 length, then the bytes" do
    assert Integrity.lp("") == <<0, 0>>
    assert Integrity.lp("abc") == <<0, 3, "abc">>
    assert Integrity.lp(:binary.copy("a", 256)) == <<1, 0>> <> :binary.copy("a", 256)
    assert_raise ArgumentError, fn -> Integrity.lp(:binary.copy("a", 65_536)) end
  end
end
