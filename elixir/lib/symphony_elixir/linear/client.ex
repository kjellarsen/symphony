defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 50
  @project_page_size 100
  @max_error_body_log_bytes 1_000

  @query """
  query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
        project {
          id
          name
          slugId
          url
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
        project {
          id
          name
          slugId
          url
        }
      }
    }
  }
  """

  @project_query """
  query SymphonyLinearProjects($first: Int!, $after: String) {
    projects(first: $first, after: $after) {
      nodes {
        id
        name
        slugId
        url
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker
    project_ref = tracker.project_slug

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      is_nil(project_ref) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, resolved_project} <- resolve_project_reference(project_ref),
             {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_states(resolved_project, tracker.active_states, assignee_filter)
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker
      project_ref = tracker.project_slug

      cond do
        is_nil(tracker.api_key) ->
          {:error, :missing_linear_api_token}

        is_nil(project_ref) ->
          {:error, :missing_linear_project_slug}

        true ->
          with {:ok, resolved_project} <- resolve_project_reference(project_ref) do
            do_fetch_by_states(resolved_project, normalized_states, nil)
          end
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        tracker = Config.settings!().tracker

        cond do
          is_nil(tracker.api_key) ->
            {:error, :missing_linear_api_token}

          is_nil(tracker.project_slug) ->
            {:error, :missing_linear_project_slug}

          true ->
            with {:ok, resolved_project} <- resolve_project_reference(tracker.project_slug),
                 {:ok, assignee_filter} <- routing_assignee_filter() do
              do_fetch_issue_states(ids, resolved_project, assignee_filter)
            end
        end
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, %{status: 401} = response} ->
        Logger.error(
          "Linear GraphQL request rejected with unauthorized status=401" <>
            linear_error_context(payload, response)
        )

        {:error, :invalid_linear_api_token}

      {:ok, response} ->
        Logger.error(
          "Linear GraphQL request failed status=#{response.status}" <>
            linear_error_context(payload, response)
        )

        {:error, {:linear_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil, map() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee, resolved_project \\ nil) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter, resolved_project)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, resolved_project} <- resolve_project_reference(Config.settings!().tracker.project_slug, graphql_fun) do
          do_fetch_issue_states(ids, resolved_project, nil, graphql_fun)
        end
    end
  end

  @doc false
  @spec resolve_project_reference_for_test(String.t(), (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def resolve_project_reference_for_test(project_ref, graphql_fun)
      when is_binary(project_ref) and is_function(graphql_fun, 2) do
    resolve_project_reference(project_ref, graphql_fun)
  end

  defp do_fetch_by_states(resolved_project, state_names, assignee_filter) do
    do_fetch_by_states_page(resolved_project, state_names, assignee_filter, nil, [])
  end

  defp do_fetch_by_states_page(resolved_project, state_names, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query, %{
             projectSlug: resolved_project.slug_id,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter, resolved_project) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(resolved_project, state_names, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, resolved_project, assignee_filter) do
    do_fetch_issue_states(ids, resolved_project, assignee_filter, &graphql/2)
  end

  defp do_fetch_issue_states(ids, resolved_project, assignee_filter, graphql_fun)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, resolved_project, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _resolved_project, _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, resolved_project, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql_fun.(@query_by_ids, %{
           ids: batch_ids,
           first: length(batch_ids),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response(body, assignee_filter, resolved_project) do
          updated_acc = prepend_page_issues(issues, acc_issues)
          do_fetch_issue_states_page(rest_ids, resolved_project, assignee_filter, graphql_fun, updated_acc, issue_order_index)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter, resolved_project) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter, resolved_project))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter, _resolved_project) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter, _resolved_project) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter,
         resolved_project
       ) do
    with {:ok, issues} <-
           decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter, resolved_project) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter, resolved_project),
    do: decode_linear_response(response, assignee_filter, resolved_project)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter, resolved_project) when is_map(issue) do
    assignee = issue["assignee"]

    if project_matches?(issue["project"], resolved_project) do
      %Issue{
        id: issue["id"],
        identifier: issue["identifier"],
        title: issue["title"],
        description: issue["description"],
        priority: parse_priority(issue["priority"]),
        state: get_in(issue, ["state", "name"]),
        branch_name: issue["branchName"],
        url: issue["url"],
        assignee_id: assignee_field(assignee, "id"),
        blocked_by: extract_blockers(issue),
        labels: extract_labels(issue),
        assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
        created_at: parse_datetime(issue["createdAt"]),
        updated_at: parse_datetime(issue["updatedAt"])
      }
    end
  end

  defp normalize_issue(_issue, _assignee_filter, _resolved_project), do: nil

  defp resolve_project_reference(project_ref, graphql_fun \\ &graphql/2)

  defp resolve_project_reference(project_ref, _graphql_fun) when not is_binary(project_ref) do
    {:error, :missing_linear_project_slug}
  end

  defp resolve_project_reference(project_ref, graphql_fun) when is_function(graphql_fun, 2) do
    normalized_ref = normalize_project_ref(project_ref)

    if is_nil(normalized_ref) do
      {:error, :missing_linear_project_slug}
    else
      do_resolve_project_reference(normalized_ref, graphql_fun, nil, [])
    end
  end

  defp do_resolve_project_reference(normalized_ref, graphql_fun, after_cursor, acc_projects) do
    case graphql_fun.(@project_query, %{first: @project_page_size, after: after_cursor}) do
      {:ok, body} ->
        with {:ok, projects, page_info} <- decode_project_page_response(body) do
          updated_projects = prepend_page_issues(projects, acc_projects)

          case next_page_cursor(page_info) do
            {:ok, next_cursor} ->
              do_resolve_project_reference(normalized_ref, graphql_fun, next_cursor, updated_projects)

            :done ->
              finalize_resolved_project(normalized_ref, finalize_paginated_issues(updated_projects))

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_project_page_response(%{
         "data" => %{
           "projects" => %{
             "nodes" => nodes,
             "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
           }
         }
       })
       when is_list(nodes) do
    {:ok, nodes, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
  end

  defp decode_project_page_response(%{"errors" => errors}) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_project_page_response(_response) do
    {:error, :linear_unknown_payload}
  end

  defp finalize_resolved_project(normalized_ref, projects) when is_list(projects) do
    matches =
      Enum.filter(projects, fn
        %{} = project -> project_matches_reference?(project, normalized_ref)
        _ -> false
      end)

    case matches do
      [%{} = project] ->
        {:ok, normalize_resolved_project(project)}

      [] ->
        {:error, {:linear_project_not_found, normalized_ref}}

      multiple ->
        {:error, {:linear_project_ambiguous, normalized_ref, Enum.map(multiple, &summarize_project_match/1)}}
    end
  end

  defp normalize_resolved_project(%{} = project) do
    %{
      id: project["id"],
      name: project["name"],
      slug_id: project["slugId"],
      url: project["url"]
    }
  end

  defp summarize_project_match(%{} = project) do
    %{
      id: project["id"],
      name: project["name"],
      slugId: project["slugId"],
      url: project["url"]
    }
  end

  defp project_matches?(%{} = project, %{slug_id: slug_id}) when is_binary(slug_id) do
    normalize_project_ref(project["slugId"]) == normalize_project_ref(slug_id)
  end

  defp project_matches?(_project, nil), do: true
  defp project_matches?(_project, _resolved_project), do: false

  defp project_matches_reference?(%{} = project, normalized_ref) when is_binary(normalized_ref) do
    project
    |> project_match_keys()
    |> MapSet.member?(normalized_ref)
  end

  defp project_match_keys(%{} = project) do
    [
      project["id"],
      project["name"],
      project["slugId"],
      project["url"],
      project_url_slug(project["url"]),
      human_project_slug(project["url"], project["slugId"])
    ]
    |> Enum.map(&normalize_project_ref/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp normalize_project_ref(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_project_ref(_value), do: nil

  defp project_url_slug(url) when is_binary(url) do
    uri = URI.parse(url)

    uri.path
    |> to_string()
    |> String.trim("/")
    |> String.split("/", trim: true)
    |> List.last()
  end

  defp project_url_slug(_url), do: nil

  defp human_project_slug(url, slug_id) when is_binary(url) and is_binary(slug_id) do
    case project_url_slug(url) do
      nil ->
        nil

      url_slug ->
        suffix = "-" <> String.downcase(String.trim(slug_id))

        if String.ends_with?(String.downcase(url_slug), suffix) do
          String.slice(url_slug, 0, byte_size(url_slug) - byte_size(suffix))
        else
          nil
        end
    end
  end

  defp human_project_slug(_url, _slug_id), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
