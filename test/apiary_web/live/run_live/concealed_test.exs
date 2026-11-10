defmodule ApiaryWeb.RunLive.ConcealedTest do
  use ExUnit.Case, async: true

  alias ApiaryWeb.RunLive.Concealed

  test "an item of the session keeps the fields its kind lists, and every other is blank" do
    tool = %{
      id: "e-5",
      seq: 5,
      kind: :tool,
      tool: "Bash",
      status: :finished,
      duration_ms: 420,
      summary: "grep -rn round",
      wells: [%{label: "input", text: "{}"}],
      error: "failed",
      # A field the list does not name yet.
      excerpt: "the first line of the output"
    }

    assert Concealed.item(tool) == %{
             id: "e-5",
             seq: 5,
             kind: :tool,
             tool: "Bash",
             status: :finished,
             duration_ms: 420,
             summary: nil,
             wells: [],
             error: nil,
             excerpt: nil
           }
  end

  test "a notification keeps its kind, and not its message" do
    notification = %{kind: :notification, notification_kind: "idle_prompt", message: "waiting"}

    assert Concealed.item(notification) == %{
             kind: :notification,
             notification_kind: "idle_prompt",
             message: nil
           }
  end

  test "the Main session row keeps its calls and how long it took, and not its words" do
    main = %{
      id: "main-session",
      seq: nil,
      sequence: 4,
      kind: :main_session,
      calls: 73,
      text_seq: 27,
      result_seqs: [29],
      words: "The checkout is now three steps.",
      duration_ms: 997_000
    }

    assert Concealed.item(main) == %{
             main
             | text_seq: nil,
               result_seqs: nil,
               words: nil
           }
  end

  test "a Pushed row is kept whole" do
    pushed = %{id: "push-v2", kind: :pushed, type: "proposal", name: "main", number: 2}
    assert Concealed.item(pushed) == pushed
    assert Concealed.kept(:pushed) == :all
  end

  test "a kind the list does not name is kept whole" do
    ended = %{kind: :session_ended, reason: "logout"}
    assert Concealed.item(ended) == ended
    assert Concealed.kept(:session_ended) == :all
    assert :agent_type in Concealed.kept(:subagent_finished)
    refute :text in Concealed.kept(:subagent_finished)
  end

  test "a background task keeps its type and id, and not what it runs" do
    background = %{
      count: 1,
      tasks: [%{id: "b3f1", type: "shell", status: "running", what: "mix test", listed_at: 9}]
    }

    assert Concealed.tasks(background) == %{
             count: 1,
             tasks: [%{id: "b3f1", type: "shell", status: "running", what: nil, listed_at: 9}]
           }
  end
end
