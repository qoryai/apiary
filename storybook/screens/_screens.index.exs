defmodule ApiaryWeb.Storybook.Screens do
  @moduledoc false
  use PhoenixStorybook.Index

  # The screen mock-ups, in the order a reader clicks through them: the shell first, then
  # the settings and the integrations, then the record (docs/ui.md, Storybook).
  def folder_name, do: "Screens"
  def folder_open?, do: true

  def entry("shell"), do: [name: "1. Sidebar and shell", index: 1]
  def entry("settings"), do: [name: "2. Settings", index: 2]
  def entry("integrations"), do: [name: "3. Integrations", index: 3]
  def entry("integration"), do: [name: "4. An integration", index: 4]
  def entry("add_integration"), do: [name: "5. Add integration", index: 5]
  def entry("run_setup"), do: [name: "6. A target's run setup", index: 6]
  def entry("access_keys"), do: [name: "7. Access keys", index: 7]
  def entry("machines"), do: [name: "8. Machines", index: 8]
end
