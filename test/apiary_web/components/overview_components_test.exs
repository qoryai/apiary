defmodule ApiaryWeb.OverviewComponentsTest do
  @moduledoc """
  What a row of the overview calls a run (`ApiaryWeb.OverviewComponents.row_title/1`).
  """
  use ExUnit.Case, async: true

  alias ApiaryWeb.OverviewComponents

  @run_id "7f3e9b20-5b1d-4c7e-9a10-2f6d0c4b7e11"

  test "a row calls a run by its title, else its command line, else its short id" do
    run = %{
      run_id: @run_id,
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

    assert OverviewComponents.row_title(%{untitled | command: nil}) == "7f3e9b20"
  end
end
