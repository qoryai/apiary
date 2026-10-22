defmodule Apiary.Registry.NamesTest do
  # The image names of the registry layout (`Apiary.Registry.Names`): the names Qory
  # Apiary makes, and `layout?/1`, the check every entry of a token passes.
  use ExUnit.Case, async: true

  alias Apiary.Registry.Names

  @instance "0123456789abcdef"
  @organisation "6f1c2a3e-0b7d-4c55-9a8e-2d4f6b8c0e11"

  test "a target's image name is the instance, the organisation and the target, each 16 hex" do
    name = Names.target_name(@instance, @organisation, "tg_example")
    assert [@instance, org, "targets", target] = String.split(name, "/")
    assert org == Names.organisation(@organisation)
    assert target == Names.target("tg_example")
    assert org =~ ~r/\A[0-9a-f]{16}\z/ and target =~ ~r/\A[0-9a-f]{16}\z/
    assert Names.layout?(name)
  end

  test "an environment image's name is of the layout" do
    key = Names.environment_key(@organisation, "env-1", "standard", ["a.example"], ["b.example"])
    name = Names.environment_name(@instance, @organisation, key)
    assert name == "#{@instance}/#{Names.organisation(@organisation)}/environments/#{key}"
    assert Names.layout?(name)
  end

  test "the environment key depends on each input, and not on the order of the hosts" do
    key = Names.environment_key(@organisation, "env-1", "m", ["b.example", "a.example"], ["c"])

    assert key ==
             Names.environment_key(@organisation, "env-1", "m", ["a.example", "b.example"], [
               "c",
               "c"
             ])

    for other <- [
          Names.environment_key(Ecto.UUID.generate(), "env-1", "m", ["a.example"], ["c"]),
          Names.environment_key(@organisation, "env-2", "m", ["a.example", "b.example"], ["c"]),
          Names.environment_key(@organisation, "env-1", "n", ["a.example", "b.example"], ["c"]),
          Names.environment_key(@organisation, "env-1", "m", ["a.example"], ["c"]),
          Names.environment_key(@organisation, "env-1", "m", ["a.example", "b.example"], ["d"])
        ] do
      assert other =~ ~r/\A[0-9a-f]{16}\z/
      refute other == key
    end
  end

  test "an instance name that is not 16 lower-case hex digits makes no name" do
    for instance <- ["shared", "upstream", "", "0123456789ABCDEF", "0123456789abcde", nil] do
      refute Names.instance?(instance)

      assert_raise MatchError, fn ->
        Names.target_name(instance, @organisation, "tg_example")
      end
    end
  end

  test "names under shared/ and upstream/ for its 4 hosts are of the layout" do
    for name <- [
          "shared/base",
          "shared/tools/node-22",
          "upstream/docker.io/library/alpine",
          "upstream/ghcr.io/example/tool",
          "upstream/mcr.microsoft.com/dotnet/sdk",
          "upstream/quay.io/example/tool"
        ] do
      assert Names.layout?(name), name
    end
  end

  test "no other name is of the layout, an empty name first" do
    long = "shared/" <> String.duplicate("a", 249)
    assert byte_size(long) == 256

    for name <- [
          "",
          "shared",
          "shared/",
          "shared//base",
          "shared/Base",
          "shared/base/",
          "shared/-base",
          "upstream",
          "upstream/docker.io",
          "upstream/registry.example/x",
          "upstream/docker.io/Library",
          "#{@instance}/#{@instance}/targets",
          "#{@instance}/#{@instance}/other/#{@instance}",
          "#{@instance}/#{@instance}/targets/#{@instance}/x",
          "#{@instance}/#{@instance}/targets/0123456789ABCDEF",
          "/#{@instance}/#{@instance}/targets/#{@instance}",
          "base",
          "library/alpine",
          long,
          nil,
          42
        ] do
      refute Names.layout?(name), inspect(name)
    end
  end
end
