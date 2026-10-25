defmodule Apiary.Integrations.ApplyTemplatesTest do
  # The apply items of a source role's work credential (`Apiary.Integrations.ApplyTemplates`):
  # which templates and hosts a start refuses, which target paths a claim refuses, and how
  # a target path fills the templates.
  use ExUnit.Case, async: true

  import Apiary.DescriptionFixtures

  alias Apiary.Integrations.{ApplyTemplates, Description}

  defp item(paths, hosts \\ ["git.example.com"]),
    do: %{"hosts" => hosts, "scheme" => "bearer", "paths" => paths}

  defp filled(items, path) do
    {:ok, filled} = ApplyTemplates.fill(items, path)
    Enum.map(filled, &Jason.decode!(Jason.encode!(&1)))
  end

  # Each space character of Forager's path grammar, as the contract lists them.
  @spaces [0x00, 0x09, 0x0A, 0x0D, 0x1F, 0x20, 0x7F, 0xFEFF, 0x85, 0xA0, 0x1680] ++
            Enum.to_list(0x2000..0x200A) ++ [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

  describe "problems/2" do
    test "takes the contract's apply examples, and none" do
      for name <- ~w(example-source-apply-basic example-source-apply-bearer
                     example-source-apply-header) do
        document = contract_description(name <> ".json")

        assert ApplyTemplates.problems(
                 document["roles"]["source"]["apply"],
                 document["egress_hosts"]
               ) == [],
               name
      end

      assert ApplyTemplates.problems(nil, []) == []
    end

    test "refuses a host with no equal entry in egress_hosts" do
      items = [item(["/{target.path}/*"], ["git.example.com", "api.git.example.com"])]

      assert ApplyTemplates.problems(items, ["git.example.com", "*.git.example.com"]) ==
               [{:apply_host_not_in_egress_hosts, "api.git.example.com"}]

      assert ApplyTemplates.problems(items, ["git.example.com", "api.git.example.com"]) == []
    end

    test "refuses a template a target path could fill out of the path grammar" do
      for template <- [
            "projects/{target.path}",
            "/{target.path}{target.path}",
            "/a/{target.path}/{target.path}",
            "/a{target.path}",
            "/a/{target.path}*",
            "/a/{target.path}.v2*",
            "/a*/{target.path}",
            "/a/{target.path}/b?",
            "/a/{target.path}#",
            "/{target}/b",
            "/a/{target.path}/{b}",
            "/a b/{target.path}",
            "/a/{target.path}" <> <<0x3000::utf8>>,
            "/a/" <> <<0xFF>> <> "/{target.path}"
          ] do
        assert ApplyTemplates.problems([item([template])], ["git.example.com"]) ==
                 [{:apply_path_invalid, template}],
               inspect(template)
      end

      for template <- [
            "/{target.path}",
            "/projects/{target.path}/*",
            "/files/{target.path}.v2/*",
            "/projects/{target.path}.json",
            "/user",
            "/user/*",
            "/"
          ] do
        assert ApplyTemplates.problems([item([template])], ["git.example.com"]) == [],
               template
      end
    end

    test "Description.parse/1 refuses an apply host that egress_hosts does not list" do
      document =
        "example-source-apply-bearer.json"
        |> contract_description()
        |> Map.put("egress_hosts", ["other.example.com"])

      assert Description.parse(Jason.encode!(document)) ==
               {:error,
                {:description_invalid, [{:apply_host_not_in_egress_hosts, "api.example.com"}]}}

      assert {:ok, description} = "example-source-apply-bearer.json" |> read_bytes()

      assert [%{"hosts" => ["api.example.com"], "scheme" => "bearer"}] =
               Description.source_apply(description)

      assert Description.exact_egress_hosts(description) == ["api.example.com"]
    end
  end

  defp read_bytes(name),
    do: name |> contract_description() |> Jason.encode!() |> Description.parse()

  describe "fill/2" do
    test "puts the target path in place of {target.path}, exactly, members in order" do
      items = [
        %{
          "paths" => ["/{target.path}.git/*", "/{target.path}/*"],
          "username" => "token-user",
          "scheme" => "basic",
          "hosts" => ["git.example.com"]
        },
        item(["/repos/{target.path}", "/repos/{target.path}/*", "/user"], [
          "api.git.example.com"
        ])
      ]

      assert {:ok, [first, _second]} = ApplyTemplates.fill(items, "Team/App%20One")
      assert Enum.map(first.values, &elem(&1, 0)) == ~w(hosts scheme username paths)

      assert filled(items, "Team/App%20One") == [
               %{
                 "hosts" => ["git.example.com"],
                 "scheme" => "basic",
                 "username" => "token-user",
                 "paths" => ["/Team/App%20One.git/*", "/Team/App%20One/*"]
               },
               %{
                 "hosts" => ["api.git.example.com"],
                 "scheme" => "bearer",
                 "paths" => [
                   "/repos/Team/App%20One",
                   "/repos/Team/App%20One/*",
                   "/user"
                 ]
               }
             ]
    end

    test "leaves out a filled path equal to an earlier one of the same item, the first kept" do
      items = [
        item(["/projects/{target.path}", "/projects/acme", "/projects/{target.path}/*"]),
        item(["/projects/acme"], ["api.example.com"])
      ]

      assert [
               %{"paths" => ["/projects/acme", "/projects/acme/*"]},
               %{"paths" => ["/projects/acme"]}
             ] = filled(items, "acme")

      assert [%{"paths" => ["/projects/other", "/projects/acme", "/projects/other/*"]}, _] =
               filled(items, "other")
    end

    test "keeps an item without paths as it is" do
      items = [%{"hosts" => ["10.0.0.5"], "scheme" => "header", "header" => "X-Api-Key"}]

      assert filled(items, "acme") == [
               %{"hosts" => ["10.0.0.5"], "scheme" => "header", "header" => "X-Api-Key"}
             ]
    end

    test "refuses a target path with .., //, *, ?, # or a space character, before filling" do
      items = [item(["/{target.path}/*"])]

      refused =
        ["a/../b", "..", "a//b", "a*", "a?b", "a#b", "", <<0xFF>>] ++
          for(code <- @spaces, do: "a" <> <<code::utf8>> <> "b")

      for path <- refused do
        assert ApplyTemplates.fill(items, path) == {:error, :path_refused}, inspect(path)
        refute ApplyTemplates.target_path?(path), inspect(path)
      end

      for path <- ["a.b", "a/.b", "a./b", "/a", "a/", "Ä/ö", "a%2F.b"] do
        assert {:ok, _items} = ApplyTemplates.fill(items, path), inspect(path)
      end
    end

    test "hosts/1 lists each host once, in order" do
      items = [item(["/"], ["a.example", "b.example"]), item(["/"], ["b.example", "c.example"])]
      assert ApplyTemplates.hosts(items) == ["a.example", "b.example", "c.example"]
    end
  end
end
