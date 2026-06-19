using System.Net.Http.Json;
using System.Text;
using System.Text.Json;

namespace AskMaya.Web.Services;

public record Source(int Id, string Title);

public record DoneInfo(string? Cache, double? Score, IReadOnlyList<Source> Sources);

/// <summary>Client-facing capabilities and limits, fetched once from the API's <c>/config</c>.</summary>
public record ChatConfig(bool PreciseModeEnabled, int MaxQuestionsPerThread, int MaxQuestionChars);

public record ChatCallbacks(
    Func<string, Task> OnSession,
    Func<IReadOnlyList<Source>, Task> OnSources,
    Func<string, Task> OnToken,
    Func<DoneInfo, Task> OnDone,
    Func<string, Task> OnError,
    Func<string, Task> OnBusy,
    Func<string, Task> OnLimit);

/// <summary>
/// Reads the FastAPI <c>/chat</c> Server-Sent Events stream and dispatches each frame to the
/// supplied callbacks. Runs server-side on the Blazor circuit, so callbacks are responsible for
/// marshalling UI updates with InvokeAsync/StateHasChanged.
/// </summary>
public sealed class ChatClient(IHttpClientFactory factory)
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    /// <summary>Fetches launch capabilities/limits; falls back to safe defaults if unavailable.</summary>
    public async Task<ChatConfig> GetConfigAsync(CancellationToken ct = default)
    {
        var client = factory.CreateClient("api");
        try
        {
            return await client.GetFromJsonAsync<ChatConfig>("/config", Json, ct)
                ?? new ChatConfig(false, 5, 500);
        }
        catch
        {
            return new ChatConfig(false, 5, 500);
        }
    }

    public async Task StreamAsync(string message, string? sessionId, string mode, ChatCallbacks cb, CancellationToken ct = default)
    {
        var client = factory.CreateClient("api");
        using var request = new HttpRequestMessage(HttpMethod.Post, "/chat")
        {
            Content = JsonContent.Create(new { message, sessionId, mode }),
        };

        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        if (!response.IsSuccessStatusCode)
        {
            await cb.OnError($"Request failed ({(int)response.StatusCode})");
            return;
        }

        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        using var reader = new StreamReader(stream, Encoding.UTF8);

        // NOTE: do NOT use reader.EndOfStream here. EndOfStream performs a *synchronous*
        // blocking read-ahead on the network stream; on a long-lived SSE response running on a
        // Blazor Server circuit that stalls the thread (tokens never dispatch, _busy never
        // clears). Loop on ReadLineAsync returning null instead — it completes per-line as the
        // server flushes each frame and returns null only when the stream actually closes.
        while (!ct.IsCancellationRequested)
        {
            var line = await reader.ReadLineAsync(ct);
            if (line is null)
            {
                break;
            }
            if (string.IsNullOrWhiteSpace(line) || !line.StartsWith("data:", StringComparison.Ordinal))
            {
                continue;
            }

            var payload = line[5..].Trim();
            JsonElement evt;
            try
            {
                evt = JsonDocument.Parse(payload).RootElement;
            }
            catch (JsonException)
            {
                continue;
            }

            var type = evt.TryGetProperty("type", out var t) ? t.GetString() : null;
            switch (type)
            {
                case "session":
                    await cb.OnSession(evt.GetProperty("sessionId").GetString() ?? "");
                    break;
                case "sources":
                    await cb.OnSources(ParseSources(evt));
                    break;
                case "token":
                    await cb.OnToken(evt.GetProperty("text").GetString() ?? "");
                    break;
                case "done":
                    await cb.OnDone(new DoneInfo(
                        evt.TryGetProperty("cache", out var c) && c.ValueKind == JsonValueKind.String ? c.GetString() : null,
                        evt.TryGetProperty("score", out var s) && s.ValueKind == JsonValueKind.Number ? s.GetDouble() : null,
                        ParseSources(evt)));
                    break;
                case "error":
                    await cb.OnError(evt.TryGetProperty("message", out var m) ? m.GetString() ?? "error" : "error");
                    break;
                case "busy":
                    await cb.OnBusy(evt.TryGetProperty("message", out var bm) ? bm.GetString() ?? "high demand" : "high demand");
                    break;
                case "limit":
                    await cb.OnLimit(evt.TryGetProperty("message", out var lm) ? lm.GetString() ?? "limit reached" : "limit reached");
                    break;
            }
        }
    }

    private static IReadOnlyList<Source> ParseSources(JsonElement evt)
    {
        if (!evt.TryGetProperty("sources", out var arr) || arr.ValueKind != JsonValueKind.Array)
        {
            return Array.Empty<Source>();
        }

        var list = new List<Source>();
        foreach (var item in arr.EnumerateArray())
        {
            var id = item.TryGetProperty("id", out var i) && i.ValueKind == JsonValueKind.Number ? i.GetInt32() : list.Count + 1;
            var title = item.TryGetProperty("title", out var ti) ? ti.GetString() ?? "Source" : "Source";
            list.Add(new Source(id, title));
        }
        return list;
    }
}
