# Stage 1: Build the Dart application
FROM dart:stable AS build

WORKDIR /app

# Copy dependencies config
COPY pubspec.yaml ./
RUN dart pub get

# Copy the rest of the code
COPY . .

# Ensure standard build structure and compile to AOT
RUN dart compile exe bin/life_assistant_bot.dart -o bin/life_assistant_bot

# Stage 2: Runtime stage
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/bin/life_assistant_bot /app/bin/life_assistant_bot

# Start the bot
CMD ["/app/bin/life_assistant_bot"]