defmodule ApiaryWeb.Storybook.Page do
  @moduledoc false
  use PhoenixStorybook.Index

  # The patterns every page is built from (`ApiaryWeb.PageComponents`).
  def folder_name, do: "Page patterns"
end
