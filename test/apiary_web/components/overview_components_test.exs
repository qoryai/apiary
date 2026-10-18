defmodule ApiaryWeb.OverviewComponentsTest do
  @moduledoc """
  What a row of the overview calls a run (`ApiaryWeb.OverviewComponents.row_title/1`).
  """
  use ExUnit.Case, async: true

  alias ApiaryWeb.OverviewComponents

  @public_id "rn_7f3e9b205b1d4c7e"

  test "a row calls a run by its title, else its command line, else its short id" do
    run = %{
      public_id: @public_id,
      about_title: "Fix the login redirect",
      labels: %{"task" => "fix-login"},
      command: "claude",
      args: ["-p", "fix the login redirect"]
    }

    assert OverviewComponents.row_title(run) == "Fix the login redirect"

    # A task is an ordinary label, never the title.
    untitled = %{run | about_title: nil}
    assert OverviewComponents.row_title(untitled) == "claude -p fix the login redirect"

    long = %{untitled | args: ["-p", String.duplicate("a", 60)]}
    assert String.length(OverviewComponents.row_title(long)) == 40
    assert OverviewComponents.row_title(long) =~ ~r/…\z/

    assert OverviewComponents.row_title(%{untitled | command: nil}) == "rn_7f3e9b20"
  end

  test "a row's title is shown as a text Forager sent is: no invisible character, no control" do
    run = %{
      public_id: @public_id,
      about_title: "Fix the#{<<0x202E::utf8>>} login",
      labels: %{},
      command: "claude",
      args: ["-p", "fix\u0085it"]
    }

    assert OverviewComponents.row_title(run) == "Fix the login"
    assert OverviewComponents.row_title(%{run | about_title: nil}) == "claude -p fix\u{FFFD}it"
  end
end
