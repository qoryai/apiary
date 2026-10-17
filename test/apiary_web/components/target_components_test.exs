defmodule ApiaryWeb.TargetComponentsTest do
  @moduledoc """
  The helpers that write a target's address, by its public id, and its name given the
  workspace's shared paths as a set (`Apiary.Runs.shared_paths/2`), as the lists pass
  them: the system only for a path in the set.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Organisation, Workspace}
  alias ApiaryWeb.TargetComponents

  @scope %Scope{organisation: %Organisation{slug: "acme"}, workspace: %Workspace{slug: "main"}}
  @shared MapSet.new(["acme/shop"])

  test "state_mark/1: a run that completed is its dot, its word for a screen reader" do
    # An older release stored completed as succeeded.
    for state <- ~w(completed succeeded) do
      html = render_component(&TargetComponents.state_mark/1, state: state)
      assert html =~ "q-sdot-#{state}"
      assert html =~ ~s(<span class="sr-only">Completed</span>)
    end

    # The word shown where it is asked for, as a header does
    html = render_component(&TargetComponents.state_mark/1, state: "completed", word: true)
    assert html =~ ">Completed</span>"
    refute html =~ "sr-only"
  end

  test "state_mark/1: every other state shows its word, a cancelled run's too" do
    for {state, word} <- [
          {"pending", "Pending"},
          {"running", "Running"},
          {"failed", "Failed"},
          {"cancelled", "Cancelled"},
          {"timed_out", "Cancelled"},
          {"ended", "Cancelled"},
          {"lost", "Lost"}
        ] do
      html = render_component(&TargetComponents.state_mark/1, state: state)
      assert html =~ "q-sdot-#{state}"
      assert html =~ ">#{word}</span>"
      refute html =~ "sr-only"
    end
  end

  test "target_path/3 writes the target's public id, never its system or its path" do
    target = %{public_id: "tg_0123456789abcdef", system: "gitlab.com", path: "acme/shop"}

    assert TargetComponents.target_path(@scope, target) ==
             "/acme/main/targets/tg_0123456789abcdef"

    assert TargetComponents.target_path(@scope, target, ["policy"]) ==
             "/acme/main/targets/tg_0123456789abcdef/policy"

    assert TargetComponents.target_path(@scope, "tg_0123456789abcdef", ["policy", "history"]) ==
             "/acme/main/targets/tg_0123456789abcdef/policy/history"

    assert TargetComponents.target_path(
             %Organisation{slug: "acme"},
             %Workspace{slug: "main"},
             target,
             ["policy", "versions", "3"]
           ) == "/acme/main/targets/tg_0123456789abcdef/policy/versions/3"
  end

  test "a target's name carries its system only for a path in the set" do
    for {system, path, shared, name} <- [
          {"gitlab.com", "acme/shop", @shared, "gitlab.com/acme/shop"},
          {"github.com", "acme/billing", @shared, "acme/billing"},
          {"codeberg.org", "acme/billing", true, "codeberg.org/acme/billing"},
          {"codeberg.org", "acme/billing", false, "acme/billing"},
          {"github.com", "acme/billing", nil, "acme/billing"},
          {nil, "acme/shop", true, "acme/shop"}
        ] do
      assert TargetComponents.target_label(system, path, shared) == name
      assert TargetComponents.with_system?(system, path, shared) == (name == "#{system}/#{path}")
    end
  end
end
