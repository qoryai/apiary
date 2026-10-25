defmodule Apiary.Runs.RunCredentialIssueTest do
  use ExUnit.Case, async: true

  alias Apiary.Runs.RunCredentialIssue

  @now ~U[2026-10-25 12:00:00Z]
  @token "example-access-token-0123456789"

  @code %{
    "hosts" => ["code.example.com"],
    "scheme" => "basic",
    "username" => "token-user",
    "paths" => ["/team/docs/*", "/team/app/*"]
  }
  @api %{
    "hosts" => ["api.example.com", "uploads.example.com"],
    "scheme" => "bearer",
    "paths" => ["/api/team/app", "/api/team/app/*"]
  }
  @files %{
    "hosts" => ["files.example.com"],
    "scheme" => "header",
    "header" => "X-Access-Key"
  }

  defp entry(items \\ [@code, @api, @files]) do
    %{
      "name" => "work-1",
      "purpose" => "work",
      "apply" => items,
      "placeholders" => ["EXAMPLE_TOKEN"]
    }
  end

  defp answer(changes \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "token" => @token,
        "expires_at" => "2026-10-25T13:00:00Z",
        "apply" => [@code, @api, @files]
      },
      changes
    )
  end

  defp items(items), do: answer(%{"apply" => items})

  defp check(answer), do: RunCredentialIssue.check(entry(), answer, @now)

  defp refused(answer), do: refused_with(entry(), answer, @now)

  defp refused_with(entry, answer, now) do
    assert {:error, cause} = RunCredentialIssue.check(entry, answer, now)
    assert cause in RunCredentialIssue.causes()
    cause
  end

  defp at(seconds), do: @now |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()

  describe "an accepted answer" do
    test "returns the token, the expiry and the answer's items" do
      assert {:ok, issue} = check(answer())
      assert RunCredentialIssue.value(issue) == @token
      assert issue.expires_at == ~U[2026-10-25 13:00:00Z]
      assert issue.apply == [@code, @api, @files]
    end

    test "with no expires_at, the credential does not expire" do
      assert {:ok, issue} = check(Map.delete(answer(), "expires_at"))
      assert issue.expires_at == nil
    end

    test "with fewer items" do
      assert {:ok, %{apply: [@api]}} = check(items([@api]))
    end

    test "with fewer hosts" do
      item = %{@api | "hosts" => ["api.example.com"]}
      assert {:ok, %{apply: [^item]}} = check(items([item]))
    end

    test "with fewer paths" do
      item = %{@code | "paths" => ["/team/app/*"]}
      assert {:ok, _issue} = check(items([item]))
    end

    test "with paths under a path that ends in *" do
      for paths <- [["/team/app/src/*"], ["/team/app/"], ["/team/app/a", "/team/docs/info/*"]] do
        assert {:ok, _issue} = check(items([%{@code | "paths" => paths}])), inspect(paths)
      end
    end

    test "with a .. path under a * entry path, since paths are compared without normalisation" do
      item = %{@code | "paths" => ["/team/app/../other/*"]}
      assert {:ok, %{apply: [^item]}} = check(items([item]))
    end

    test "with paths where the entry item has none" do
      item = Map.put(@files, "paths", ["/files/*", "/anything"])
      assert {:ok, _issue} = check(items([item]))
    end

    test "with two answer items inside one entry item" do
      first = %{@api | "hosts" => ["api.example.com"]}
      second = %{@api | "hosts" => ["uploads.example.com"], "paths" => ["/api/team/app/x"]}
      assert {:ok, _issue} = check(items([first, second]))
    end

    test "with a tab inside the token" do
      token = "first\tsecond"
      assert {:ok, issue} = check(answer(%{"token" => token}))
      assert RunCredentialIssue.value(issue) == token
    end

    test "with an expiry at an offset and with fractional seconds" do
      assert {:ok, issue} = check(answer(%{"expires_at" => "2026-10-25T15:00:00.250+02:00"}))
      assert issue.expires_at == ~U[2026-10-25 13:00:00.250Z]
    end

    test "with an entry that has no name, purpose or placeholders" do
      assert {:ok, _issue} = RunCredentialIssue.check(%{"apply" => [@api]}, items([@api]), @now)
    end
  end

  describe "a wider answer" do
    test "another host is refused" do
      item = %{@api | "hosts" => ["api.example.com", "other.example.com"]}
      assert refused(items([item])) == :host_outside_entry
    end

    test "a host in another letter case is refused" do
      assert refused(items([%{@api | "hosts" => ["API.example.com"]}])) == :host_outside_entry
    end

    test "a host of another entry item with the same scheme is refused" do
      item = %{@code | "hosts" => ["api.example.com"]}
      assert refused(items([item])) == :host_outside_entry
    end

    test "hosts spread across two entry items with the same scheme are refused" do
      first = %{"hosts" => ["one.example.com"], "scheme" => "bearer", "paths" => ["/a/*"]}
      second = %{"hosts" => ["two.example.com"], "scheme" => "bearer", "paths" => ["/a/*"]}
      item = %{first | "hosts" => ["one.example.com", "two.example.com"]}

      assert refused_with(entry([first, second]), items([item]), @now) == :host_outside_entry

      assert {:ok, _issue} =
               RunCredentialIssue.check(entry([first, second]), items([first, second]), @now)
    end

    test "a percent-encoded path is refused" do
      assert refused(items([%{@code | "paths" => ["/team/%61pp/*"]}])) == :path_outside_entry
      assert refused(items([%{@code | "paths" => ["/team%2Fapp/x"]}])) == :path_outside_entry
    end

    test "a path beside a * prefix and not under it is refused" do
      assert refused(items([%{@code | "paths" => ["/team/app*"]}])) == :path_outside_entry
      assert refused(items([%{@code | "paths" => ["/team/apps/x"]}])) == :path_outside_entry
    end

    test "a wider path than an exact entry path is refused" do
      assert refused(items([%{@api | "paths" => ["/api/team/app*"]}])) == :path_outside_entry
      assert refused(items([%{@api | "paths" => ["/api/team/*"]}])) == :path_outside_entry
    end

    test "a path in another letter case is refused" do
      assert refused(items([%{@code | "paths" => ["/Team/app/*"]}])) == :path_outside_entry
    end

    test "missing paths where the entry item has paths are refused" do
      assert refused(items([Map.delete(@code, "paths")])) == :path_outside_entry
    end

    test "another scheme is refused" do
      item = @api |> Map.put("scheme", "basic") |> Map.put("username", "api-user")
      assert refused(items([item])) == :scheme_outside_entry
      assert refused(items([%{@api | "scheme" => "digest"}])) == :scheme_outside_entry
    end

    test "another username, or none, is refused" do
      assert refused(items([%{@code | "username" => "other-user"}])) == :scheme_outside_entry
      assert refused(items([Map.delete(@code, "username")])) == :scheme_outside_entry
      assert refused(items([Map.put(@api, "username", "token-user")])) == :scheme_outside_entry
    end

    test "another header, in any letter case, or none, is refused" do
      assert refused(items([%{@files | "header" => "X-Other-Key"}])) == :scheme_outside_entry
      assert refused(items([%{@files | "header" => "x-access-key"}])) == :scheme_outside_entry
      assert refused(items([Map.delete(@files, "header")])) == :scheme_outside_entry
    end

    test "one wider item among narrower ones is refused" do
      wide = %{@api | "hosts" => ["other.example.com"]}
      assert refused(items([@code, wide, @files])) == :host_outside_entry
    end
  end

  describe "the token" do
    test "absent or not a string is refused" do
      assert refused(Map.delete(answer(), "token")) == :token_missing

      for token <- [nil, 123, ["x"], %{"value" => "x"}],
          do: assert(refused(answer(%{"token" => token})) == :token_missing)
    end

    test "1 to 16,384 bytes is accepted, 0 or 16,385 is refused" do
      for token <- ["a", String.duplicate("a", 16_384)],
          do: assert({:ok, _issue} = check(answer(%{"token" => token})))

      for token <- ["", String.duplicate("a", 16_385)],
          do: assert(refused(answer(%{"token" => token})) == :token_size)
    end

    test "counts bytes, not characters, with a multi-byte character at the limit" do
      at_limit = String.duplicate("a", 16_382) <> "é"
      over = String.duplicate("a", 16_383) <> "é"
      assert byte_size(at_limit) == 16_384 and byte_size(over) == 16_385
      assert {:ok, _issue} = check(answer(%{"token" => at_limit}))
      assert refused(answer(%{"token" => over})) == :token_size
      assert refused(answer(%{"token" => String.duplicate("é", 8193)})) == :token_size
    end

    test "invalid UTF-8 is refused" do
      for token <- [<<0xFF>>, "abc" <> <<0xC3>>, <<0xED, 0xA0, 0x80>>],
          do: assert(refused(answer(%{"token" => token})) == :token_encoding)
    end

    test "a control character other than tab is refused" do
      for c <- [0x00, 0x01, 0x0A, 0x0D, 0x1B, 0x1F, 0x7F, 0x80, 0x85, 0x9F] do
        token = "abc" <> <<c::utf8>> <> "def"
        assert refused(answer(%{"token" => token})) == :token_control_character, inspect(c)
      end
    end

    test "U+00A0 and other characters above U+009F are accepted" do
      assert {:ok, _issue} = check(answer(%{"token" => "a b€c"}))
    end

    test "a space or tab at the start or the end is refused" do
      for token <- [" abc", "abc ", "\tabc", "abc\t", " ", "\t"],
          do: assert(refused(answer(%{"token" => token})) == :token_padded)
    end

    test "a token in an apply item is refused" do
      item = Map.put(@api, "token", "another-token")
      assert refused(items([item])) == :token_in_apply_item
    end
  end

  describe "placeholders, members and version" do
    test "an answer with placeholders is refused, even the entry's" do
      for names <- [["EXAMPLE_TOKEN"], [], nil],
          do: assert(refused(answer(%{"placeholders" => names})) == :placeholders_present)
    end

    test "a member the contract does not define is refused" do
      assert refused(answer(%{"refresh" => "x"})) == :unknown_member
      assert refused(answer(%{revision: 1})) == :unknown_member
      assert refused(items([Map.put(@api, "expires_at", "x")])) == :unknown_member
    end

    test "a version other than 1, or none, is refused" do
      for version <- [2, 0, "1", 1.0, nil],
          do: assert(refused(answer(%{"version" => version})) == :version_unsupported)

      assert refused(Map.delete(answer(), "version")) == :version_unsupported
    end
  end

  describe "the apply member" do
    test "absent, not a list, empty or over 16 items is refused" do
      assert refused(Map.delete(answer(), "apply")) == :apply_invalid

      for apply <- [nil, "x", @api, [], List.duplicate(@api, 17)],
          do: assert(refused(answer(%{"apply" => apply})) == :apply_invalid)
    end

    test "16 items inside the entry are accepted" do
      assert {:ok, _issue} = check(items(List.duplicate(@api, 16)))
    end

    test "an item of the wrong shape is refused" do
      for item <- [
            nil,
            "x",
            [@api],
            Map.delete(@api, "hosts"),
            Map.delete(@api, "scheme"),
            %{@api | "hosts" => []},
            %{@api | "hosts" => "api.example.com"},
            %{@api | "hosts" => ["api.example.com", "api.example.com"]},
            %{@api | "hosts" => [nil]},
            %{@api | "hosts" => Enum.map(1..17, &"h#{&1}.example.com")},
            %{@api | "scheme" => :bearer},
            Map.put(@api, "username", 1),
            Map.put(@files, "header", nil),
            %{@api | "paths" => []},
            %{@api | "paths" => "/api/team/app"},
            %{@api | "paths" => ["/api/team/app", "/api/team/app"]},
            %{@api | "paths" => Enum.map(1..33, &"/api/team/app/#{&1}")}
          ] do
        assert refused(items([item])) == :apply_item_invalid, inspect(item)
      end
    end

    test "a path outside the path grammar is refused" do
      for path <- [
            "/api/team/app/x?y",
            "/api/team/app/x#y",
            "/api/team/app/x y",
            "/api/team/app/x y",
            "/api/team/app/*/x",
            "/api/team/app/**",
            "api/team/app",
            "/api/team/app/" <> <<0xFF>>
          ] do
        assert refused(items([%{@api | "paths" => [path]}])) == :apply_item_invalid,
               inspect(path)
      end
    end
  end

  describe "expires_at" do
    test "more than 6 minutes and at most 24 hours after now is accepted" do
      for seconds <- [6 * 60 + 1, 3600, 24 * 3600] do
        assert {:ok, issue} = check(answer(%{"expires_at" => at(seconds)}))
        assert issue.expires_at == DateTime.add(@now, seconds, :second)
      end
    end

    test "exactly 6 minutes after now, or less, is refused" do
      for seconds <- [6 * 60, 5 * 60, 0, -60],
          do: assert(refused(answer(%{"expires_at" => at(seconds)})) == :expires_at_too_soon)
    end

    test "6 minutes and a microsecond after now is accepted" do
      assert {:ok, _issue} = check(answer(%{"expires_at" => "2026-10-25T12:06:00.000001Z"}))
    end

    test "more than 24 hours after now is refused" do
      for value <- [at(24 * 3600 + 1), "2026-10-26T12:00:00.000001Z", "2027-01-01T00:00:00Z"],
          do: assert(refused(answer(%{"expires_at" => value})) == :expires_at_too_late)
    end

    test "a lower-case t and z, -00:00 and any number of fraction digits are accepted" do
      for {value, expected} <- [
            {"2026-10-25t13:00:00z", ~U[2026-10-25 13:00:00Z]},
            {"2026-10-25t15:00:00+02:00", ~U[2026-10-25 13:00:00Z]},
            {"2026-10-25T13:00:00-00:00", ~U[2026-10-25 13:00:00Z]},
            {"2026-10-25T13:00:00.5Z", ~U[2026-10-25 13:00:00.5Z]},
            {"2026-10-25T13:00:00.1234567891Z", ~U[2026-10-25 13:00:00.123456Z]}
          ] do
        assert {:ok, issue} = check(answer(%{"expires_at" => value})), value
        assert DateTime.compare(issue.expires_at, expected) == :eq, value
      end
    end

    test "24 hours and 0.0000009 seconds after now is cut to 24 hours and accepted" do
      assert {:ok, issue} = check(answer(%{"expires_at" => "2026-10-26T12:00:00.0000009Z"}))
      assert DateTime.compare(issue.expires_at, ~U[2026-10-26 12:00:00Z]) == :eq
    end

    test "a leap second is refused, because a DateTime has no value for second 60" do
      for value <- ["2026-10-25T23:59:60Z", "2026-12-31T23:59:60.5z"],
          do: assert(refused(answer(%{"expires_at" => value})) == :expires_at_invalid)
    end

    test "a value that is not an RFC 3339 date-time is refused" do
      for value <- [
            nil,
            1_793_000_000,
            "",
            "soon",
            "2026-10-25",
            "2026-10-25T13:00:00",
            "2026-10-25 13:00:00Z",
            "2026-10-25T13:00:00.Z",
            "2026-10-25T13:00:00+0100",
            "2026-10-25T13:00Z",
            "2026-02-30T13:00:00Z",
            "2026-10-25T25:00:00Z",
            "+2026-10-25T13:00:00Z",
            "2026-10-25T13:00:00Z\n"
          ] do
        assert refused(answer(%{"expires_at" => value})) == :expires_at_invalid, inspect(value)
      end
    end
  end

  describe "the arguments" do
    test "a now that is not a DateTime in UTC is refused" do
      for now <- [nil, ~N[2026-10-25 12:00:00], "2026-10-25T12:00:00Z", 0] do
        assert refused_with(entry(), answer(), now) == :now_invalid
      end

      brussels = %{@now | time_zone: "Europe/Brussels", zone_abbr: "CET", utc_offset: 3600}
      assert refused_with(entry(), answer(), brussels) == :now_invalid
    end

    test "an entry of the wrong shape is refused" do
      for entry <- [
            nil,
            [],
            %{},
            %{"apply" => []},
            %{"apply" => @api},
            %{"apply" => List.duplicate(@api, 17)},
            %{"apply" => [nil]},
            %{"apply" => [Map.delete(@api, "hosts")]},
            %{"apply" => [%{@api | "hosts" => []}]},
            %{"apply" => [%{@api | "scheme" => "digest"}]},
            %{"apply" => [%{@api | "paths" => []}]},
            %{"apply" => [%{@api | "paths" => [1]}]},
            %{"apply" => [Map.put(@api, "token", "x")]},
            %{"apply" => [@api], "value" => "x"},
            %{"apply" => [@api], "placeholders" => "EXAMPLE_TOKEN"},
            %{apply: [@api]}
          ] do
        assert refused_with(entry, answer(), @now) == :entry_invalid, inspect(entry)
      end
    end

    test "a credential that is not a map is refused" do
      for credential <- [nil, [], "x", 1, [answer()]],
          do: assert(refused(credential) == :answer_invalid)
    end

    test "a wrong type at any member is refused with a cause, never an exception" do
      wrong = [nil, 2, "", [], %{}, [nil], [%{}], :atom, 1.5]

      for key <- ["version", "token", "expires_at", "apply", "placeholders"], value <- wrong do
        assert refused(answer(%{key => value})) in RunCredentialIssue.causes()
      end

      for key <- ["hosts", "scheme", "username", "header", "paths", "token"], value <- wrong do
        assert refused(items([Map.put(@code, key, value)])) in RunCredentialIssue.causes()
      end
    end
  end

  describe "causes/0" do
    test "lists each cause once, and each one has a case" do
      cases = %{
        now_invalid: refused_with(entry(), answer(), nil),
        entry_invalid: refused_with(nil, answer(), @now),
        answer_invalid: refused(nil),
        unknown_member: refused(answer(%{"other" => 1})),
        version_unsupported: refused(answer(%{"version" => 2})),
        placeholders_present: refused(answer(%{"placeholders" => ["EXAMPLE_TOKEN"]})),
        token_missing: refused(Map.delete(answer(), "token")),
        token_size: refused(answer(%{"token" => ""})),
        token_encoding: refused(answer(%{"token" => <<0xFF>>})),
        token_control_character: refused(answer(%{"token" => "a\0b"})),
        token_padded: refused(answer(%{"token" => "a "})),
        apply_invalid: refused(answer(%{"apply" => []})),
        apply_item_invalid: refused(items([nil])),
        token_in_apply_item: refused(items([Map.put(@api, "token", "x")])),
        scheme_outside_entry: refused(items([%{@files | "header" => "X-Other"}])),
        host_outside_entry: refused(items([%{@api | "hosts" => ["x.example.com"]}])),
        path_outside_entry: refused(items([%{@api | "paths" => ["/other"]}])),
        expires_at_invalid: refused(answer(%{"expires_at" => "soon"})),
        expires_at_too_soon: refused(answer(%{"expires_at" => at(360)})),
        expires_at_too_late: refused(answer(%{"expires_at" => at(86_401)}))
      }

      causes = RunCredentialIssue.causes()
      assert causes == Enum.uniq(causes)
      assert Enum.sort(Map.keys(cases)) == Enum.sort(causes)
      for {cause, result} <- cases, do: assert(result == cause)
    end
  end

  describe "the token stays out of every output" do
    @secret "fixed-secret-token-5e1f9c"

    test "inspect shows no token, with or without structs: false" do
      assert {:ok, issue} = check(answer(%{"token" => @secret}))
      assert RunCredentialIssue.value(issue) == @secret

      for output <- [
            inspect(issue),
            inspect({:ok, issue}),
            inspect(issue, structs: false),
            inspect({:ok, issue}, structs: false, limit: :infinity, printable_limit: :infinity),
            inspect(Map.from_struct(issue), limit: :infinity)
          ] do
        refute output =~ @secret
        refute output =~ "5e1f9c"
      end

      assert inspect(issue) =~ "expires_at"
      refute inspect(issue) =~ "value"
    end

    test "no cause contains the token or the answer" do
      answers = [
        answer(%{"token" => @secret <> " "}),
        answer(%{"token" => @secret <> "\0"}),
        answer(%{"token" => @secret, "placeholders" => [@secret]}),
        answer(%{"token" => @secret, @secret => @secret}),
        answer(%{"token" => @secret, "version" => @secret}),
        answer(%{"token" => @secret, "expires_at" => @secret}),
        answer(%{"token" => @secret, "apply" => @secret}),
        items([Map.put(@api, "token", @secret)]),
        items([%{@api | "hosts" => [@secret]}]),
        items([%{@api | "paths" => ["/" <> @secret]}]),
        items([%{@api | "scheme" => @secret}]),
        items([Map.put(@api, @secret, @secret)]),
        [answer(%{"token" => @secret})]
      ]

      for answer <- answers do
        result = check(answer)
        assert {:error, cause} = result
        assert is_atom(cause)
        refute inspect(result, limit: :infinity, printable_limit: :infinity) =~ @secret
        refute Atom.to_string(cause) =~ @secret
      end
    end
  end
end
