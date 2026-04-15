#!/bin/bash

# Check if there are any missing commands.
for command in netcat jq
do
command -v $command>/dev/null || { echo "$command is not installed."; exit 1; }
done

# Print help text usage information.
usage() {
  echo "Usage: $(basename "$0") [OPTION]..."
  echo "Start the social media server."
  echo
  echo "  -a <address>   set the address (defaults to 'localhost')"
  echo "  -p <port>      set the port number (defaults to '8000')"
  echo "  -h             display this help text"
}

# Parse command line flags.
port='8000'
address='localhost'

while getopts 'a:p:h' flag; do
  case "${flag}" in
    p) port="${OPTARG}" ;;
    a) address="${OPTARG}" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

# Start the server.
echo "Listening on $address:$port"

# Create db files if it doesn't exist.
mkdir -p db
if [ ! -f db/posts.json ]; then echo "[]" > db/posts.json; fi
if [ ! -f db/accounts.json ]; then echo "{}" > db/accounts.json; fi

# Create a named pipe. Anything put into here will be the response data to a request.
response=/tmp/ogj-social-media-response-pipe
rm -f $response
mkfifo $response

get_body() {
  # Get Content-Length
  length='0'
  while read -t10 line; do
    line=$(echo "$line" | tr -d '[\r\n]')
    if [ -z "$line" ]; then break; fi
    prop=$(echo "$line" | cut -d':' -f1 | tr -d ' ')
    val=$(echo "$line" | cut -d':' -f2 | tr -d ' ')
    case "${prop}" in
      Content-Length) length="$val" ;;
      *) ;;
    esac
  done

  # Read Content-Length amount of bytes from stdin to stdout
  timeout 10 head -c "$length"
}

# Handle a login request.
login() {
  body=$(get_body)
  username=$(echo "$body" | jq -r .username)
  password=$(echo "$body" | jq -r .password)

  # Create an account, log in to an existing one, or error.
  entry=$(cat db/accounts.json | jq -r '.[$username]' --arg username "$username")
  if [ "$entry" == "null" ]; then
    # Check username length
    if (("${#username}" > 30)) || (("${#username}" < 1)); then
      cat <(echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"error\":\"Username must be between 1 and 30 characters.\"}") > $response
      return
    fi

    # Salt password and write to database
    salt=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 64)
    saltedpasswd=$(cat <(echo "$salt") <(echo "$password") | sha256sum | rev|cut -c4-|rev)
    tmp=$(mktemp)
    cat db/accounts.json | jq -cr '.[$username] = {"password":$password,"salt":$salt}' \
      --arg username "$username" \
      --arg password "$saltedpasswd" \
      --arg salt "$salt" > $tmp
    cat $tmp > db/accounts.json
    cat <(echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"success\":\"Your account has been registered.\"}") > $response
  else
    # Compare password to database entry
    entrypasswd=$(echo "$entry" | jq -r '.password')
    entrysalt=$(echo "$entry" | jq -r '.salt')
    saltedpasswd=$(cat <(echo "$entrysalt") <(echo "$password") | sha256sum | rev|cut -c4-|rev)
    if [ "$saltedpasswd" == "$entrypasswd" ]; then
      cat <(echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"success\":\"Logged in successfully!\"}") > $response
    else
      cat <(echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"error\":\"Username already taken or incorrect password.\"}") > $response
    fi
  fi
}

# Handle a make post request.
post() {
  body=$(get_body)
  username=$(echo "$body" | jq -r .account.username)
  password=$(echo "$body" | jq -r .account.password)
  text=$(echo "$body" | jq -r .text)
  
  # Send post unless username or password doesn't match.
  entry=$(cat db/accounts.json | jq -r '.[$username]' --arg username "$username")
  if [ "$entry" == "null" ]; then
    cat <(echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"error\":\"Incorrect username or password.\"}") > $response
  else
    entrypasswd=$(echo "$entry" | jq -r '.password')
    entrysalt=$(echo "$entry" | jq -r '.salt')
    saltedpasswd=$(cat <(echo "$entrysalt") <(echo "$password") | sha256sum | rev|cut -c4-|rev)
    if [ "$saltedpasswd" == "$entrypasswd" ]; then
      tmp=$(mktemp)
      cat db/posts.json | jq -cr '. += [[$text,$username,$date]]' \
        --arg text "$text" \
        --arg username "$username" \
        --arg date "$(date --iso-8601=minutes)" > $tmp
      cat $tmp > db/posts.json
      cat <(echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"success\":\"Sent!\"}") > $response
    else
      cat <(echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"error\":\"Incorrect username or password.\"}") > $response
    fi
  fi

}

# Handle an incoming request
handle_request() {
  # Read request
  read -t10 header;
  type=$(echo "$header" | cut -d' ' -f1 )
  path=$(echo "$header" | cut -d' ' -f2 )
  version=$(echo "$header" | cut -d' ' -f3 )

  echo $type $path $version

  # Send response
  case "${path}" in
    /login) login ;;
    /post) post ;;
    /posts.json) cat <(echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n") db/posts.json > $response ;;
    /) cat <(echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n") index.html > $response ;;
    *) cat <(echo -e "HTTP/1.1 404 NotFound\r\nContent-Type: text/html\r\n\r\n") 404.html > $response ;;
  esac
}

# Handle network IO
while true
do
cat $response | netcat -lN "$address" "$port" | handle_request
done