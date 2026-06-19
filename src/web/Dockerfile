FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /src
COPY web.csproj .
RUN dotnet restore web.csproj
COPY . .
RUN dotnet publish web.csproj -c Release -o /app/publish /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS final
WORKDIR /app
# Container Apps ingress terminates TLS and forwards HTTP to this port.
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "web.dll"]
