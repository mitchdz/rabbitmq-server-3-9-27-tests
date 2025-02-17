## This Source Code Form is subject to the terms of the Mozilla Public
## License, v. 2.0. If a copy of the MPL was not distributed with this
## file, You can obtain one at https://mozilla.org/MPL/2.0/.
##
## Copyright (c) 2007-2021 VMware, Inc. or its affiliates.  All rights reserved.

defmodule RabbitMQ.CLI.Plugins.Commands.EnableCommand do
  alias RabbitMQ.CLI.Plugins.Helpers, as: PluginHelpers
  alias RabbitMQ.CLI.Core.{DocGuide, Validators}
  import RabbitMQ.CLI.Core.{CodePath, Paths}

  @behaviour RabbitMQ.CLI.CommandBehaviour

  def formatter(), do: RabbitMQ.CLI.Formatters.Plugins

  def merge_defaults(args, opts) do
    {args, Map.merge(%{online: false, offline: false, all: false}, opts)}
  end

  def distribution(%{offline: true}), do: :none
  def distribution(%{offline: false}), do: :cli

  def switches(), do: [online: :boolean, offline: :boolean, all: :boolean]

  def validate([], %{all: false}) do
    {:validation_failure, :not_enough_args}
  end

  def validate([_ | _], %{all: true}) do
    {:validation_failure, {:bad_argument, "Cannot set both --all and a list of plugins"}}
  end

  def validate(_, %{online: true, offline: true}) do
    {:validation_failure, {:bad_argument, "Cannot set both online and offline"}}
  end

  def validate(_, _) do
    :ok
  end

  def validate_execution_environment(args, opts) do
    Validators.chain(
      [
        &PluginHelpers.can_set_plugins_with_mode/2,
        &require_rabbit_and_plugins/2,
        &PluginHelpers.enabled_plugins_file/2,
        &plugins_dir/2
      ],
      [args, opts]
    )
  end

  def run(plugin_names, %{all: all_flag} = opts) do
    plugins =
      case all_flag do
        false -> for s <- plugin_names, do: String.to_atom(s)
        true -> PluginHelpers.plugin_names(PluginHelpers.list(opts))
      end

    case PluginHelpers.validate_plugins(plugins, opts) do
      :ok -> do_run(plugins, opts)
      other -> other
    end
  end

  use RabbitMQ.CLI.Plugins.ErrorOutput

  def banner([], %{all: true, node: node_name}) do
    "Enabling ALL plugins on node #{node_name}"
  end

  def banner(plugins, %{node: node_name}) do
    ["Enabling plugins on node #{node_name}:" | plugins]
  end

  def usage, do: "enable <plugin1> [ <plugin2>] | --all [--offline] [--online]"

  def usage_additional() do
    [
      ["<plugin1> [ <plugin2>]", "names of plugins to enable separated by a space"],
      ["--online", "contact target node to enable the plugins. Changes are applied immediately."],
      [
        "--offline",
        "update enabled plugins file directly without contacting target node. Changes will be delayed until the node is restarted."
      ],
      [
        "--all",
        "enable all available plugins. Not recommended as some plugins may conflict or otherwise be incompatible!"
      ]
    ]
  end

  def usage_doc_guides() do
    [
      DocGuide.plugins()
    ]
  end

  def help_section(), do: :plugin_management

  def description(), do: "Enables one or more plugins"

  #
  # Implementation
  #

  def do_run(plugins, %{node: node_name} = opts) do
    enabled = PluginHelpers.read_enabled(opts)
    all = PluginHelpers.list(opts)
    implicit = :rabbit_plugins.dependencies(false, enabled, all)
    enabled_implicitly = MapSet.difference(MapSet.new(implicit), MapSet.new(enabled))

    plugins_to_set =
      MapSet.union(
        MapSet.new(enabled),
        MapSet.difference(MapSet.new(plugins), enabled_implicitly)
      )

    mode = PluginHelpers.mode(opts)

    case PluginHelpers.set_enabled_plugins(MapSet.to_list(plugins_to_set), opts) do
      {:ok, enabled_plugins} ->
        {:stream,
         Stream.concat([
           [:rabbit_plugins.strictly_plugins(enabled_plugins, all)],
           RabbitMQ.CLI.Core.Helpers.defer(fn ->
             case PluginHelpers.update_enabled_plugins(enabled_plugins, mode, node_name, opts) do
               %{set: new_enabled} = result ->
                 enabled = new_enabled -- implicit

                 filter_strictly_plugins(
                   Map.put(result, :enabled, :rabbit_plugins.strictly_plugins(enabled, all)),
                   all,
                   [:set, :started, :stopped]
                 )

               other ->
                 other
             end
           end)
         ])}

      {:error, _} = err ->
        err
    end
  end

  defp filter_strictly_plugins(map, _all, []) do
    map
  end

  defp filter_strictly_plugins(map, all, [head | tail]) do
    case map[head] do
      nil ->
        filter_strictly_plugins(map, all, tail)

      other ->
        value = :rabbit_plugins.strictly_plugins(other, all)
        filter_strictly_plugins(Map.put(map, head, value), all, tail)
    end
  end
end
