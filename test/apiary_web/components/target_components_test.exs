defmodule ApiaryWeb.TargetComponentsTest do
  @moduledoc """
  The helpers that write a target's address and its lists' parameters given the
  workspace's shared paths as a set (`Apiary.Runs.shared_paths/2`), as the lists pass them:
  the system only for a path in the set.
  """
  use ExUnit.Case, async: true

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Filters
  alias ApiaryWeb.TargetComponents

  @scope %Scope{organisation: %Organisation{slug: "acme"}, workspace: %Workspace{slug: "main"}}
  @shared MapSet.new(["acme/shop"])

  test "target_path/5 writes the system only for a path in the set" do
    assert TargetComponents.target_path(@scope, "gitlab.com", "acme/shop", [], @shared) ==
             "/acme/main/targets/gitlab.com/acme/shop"

    assert TargetComponents.target_path(@scope, "gitlab.com", "acme/shop", ["policy"], @shared) ==
             "/acme/main/targets/gitlab.com/acme/shop/-/policy"

    assert TargetComponents.target_path(@scope, "github.com", "acme/billing", [], @shared) ==
             "/acme/main/targets/acme/billing"

    assert TargetComponents.target_path(@scope, "github.com", "acme/billing", [], MapSet.new()) ==
             "/acme/main/targets/acme/billing"
  end

  test "a target's name carries its system exactly where its address does" do
    for {system, path, shared} <- [
          {"gitlab.com", "acme/shop", @shared},
          {"github.com", "acme/billing", @shared},
          {"codeberg.org", "acme/billing", true},
          {"codeberg.org", "acme/billing", false},
          {"github.com", "acme/billing", nil},
          {nil, "acme/shop", true}
        ] do
      with_system? = TargetComponents.with_system?(system, path, shared)
      address = TargetComponents.target_path(@scope, system, path, [], shared)
      name = TargetComponents.target_label(system, path, shared)

      assert address == "/acme/main/targets/" <> name
      assert with_system? == (name == "#{system}/#{path}")
      assert with_system? == String.starts_with?(address, "/acme/main/targets/#{system}/")
    end

    assert TargetComponents.target_label("codeberg.org", "acme/billing", true) ==
             "codeberg.org/acme/billing"

    assert TargetComponents.target_label("codeberg.org", "acme/billing", false) == "acme/billing"
  end

  test "Filters.target_params/3 gives the system only for a path in the set" do
    assert Filters.target_params("gitlab.com", "acme/shop", @shared) ==
             %{"system" => "gitlab.com", "target" => "acme/shop"}

    assert Filters.target_params("github.com", "acme/billing", @shared) ==
             %{"target" => "acme/billing"}

    assert Filters.target_params("github.com", "acme/shop", MapSet.new()) ==
             %{"target" => "acme/shop"}
  end
end
