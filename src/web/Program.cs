using AskMaya.Web.Components;
using AskMaya.Web.Services;

var builder = WebApplication.CreateBuilder(args);

// Blazor Server (interactive) — stateful UI over a SignalR circuit on App Service.
builder.Services.AddRazorComponents()
    .AddInteractiveServerComponents();

// Server-side HttpClient to the FastAPI chat API. Base URL is injected by App Service
// app setting "ApiBase" (the Container App endpoint); falls back to local uvicorn in dev.
builder.Services.AddHttpClient("api", client =>
{
    var baseUrl = builder.Configuration["ApiBase"] ?? "http://localhost:8000";
    client.BaseAddress = new Uri(baseUrl);
    client.Timeout = TimeSpan.FromMinutes(5); // long-lived SSE stream
});
builder.Services.AddScoped<ChatClient>();

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error", createScopeForErrors: true);
    app.UseHsts();
}

app.UseHttpsRedirection();
app.UseStaticFiles();
app.UseAntiforgery();

app.MapRazorComponents<App>()
    .AddInteractiveServerRenderMode();

app.Run();
