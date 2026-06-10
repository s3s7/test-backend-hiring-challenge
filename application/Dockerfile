FROM ruby:3.4.8

ARG WATCHMAN_VERSION=v2024.01.22.00

RUN apt-get update -qq && apt-get install -y build-essential default-mysql-client nodejs npm vim curl git

WORKDIR /app

COPY . .

RUN bundle install

EXPOSE 3000

CMD ["bin/dev"]
