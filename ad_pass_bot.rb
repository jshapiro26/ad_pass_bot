require 'rubygems'
require 'net/ldap'
require 'slack-ruby-client'
require 'active_support/core_ext/numeric/time'
require 'dotenv'
require 'pry-nav'
Dotenv.load

# Initialize hashes and arrays for later
users = {}
users_to_notify = {}
ous_to_check = [ENV['OU_1'], ENV['OU_2'], ENV['OU_3']]

## AD
# Initialize connection to AD
ldap = Net::LDAP.new :host => ENV['AD_HOST'],
    :port => 636,
    :base => ENV['AD_BASE'],
    :encryption => :simple_tls,
    :auth => {
      :method => :simple,
      :username => ENV['AD_USERNAME'],
      :password => ENV['AD_PASSWORD']
    }

# Find all users and relevant attributes
ous_to_check.each do |ou|
  filter = Net::LDAP::Filter.eq("ObjectClass", "user")
  treebase = "OU=#{ou},#{ENV['TREEBASE']}"

  ldap.search(:base => treebase, :filter => filter) do |entry|
    attributes = {}
    attributes[:mail] = entry.mail.join
    attributes[:PwdExpireTime] = Time.at(entry.PwdLastSet.join.to_i) + 90.days
    users[entry.name.join] = attributes
    puts attributes
  end
end

# Determine users with passwords about to expire
users.each do |user, attr|
  if Time.now >= (attr[:PwdExpireTime] - 5.days)
    users_to_notify[attr[:mail]] = {:PwdExpireTime => attr[:PwdExpireTime]}
  else 
    puts "Will not notify #{user}, password expires in greater than 5 days: #{attr[:PwdExpireTime]}"
  end
end

## Slack
# Initialize Slack Connection
Slack.configure do |config|
  config.token = ENV['SLACK_API_TOKEN']
end
client = Slack::Web::Client.new
# Find Slack usernames and add to hash
slack_users = client.users_list.to_hash
slack_users["members"].each do |user|
  if users_to_notify.include?(user["profile"]["email"])
    users_to_notify[user["profile"]["email"]][:slack_name] = user["name"]
  end
end
# Notify users
users_to_notify.each do |user, attr|
  client.chat_postMessage(channel: "@#{attr[:slack_name]}", text: "Your password will expire in less than 5 days at: #{attr[:PwdExpireTime]}. Reset your password by going to: #{ENV['PW_REST_URL']}", as_user: true)
end