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

# How many days from password change does a password expire?
expire_after = ENV['EXPIRE_AFTER'].to_i

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

# Initialize array for users with no mail attribute set in Active Directory
bad_user_entries = []

# Find all users and relevant attributes
ous_to_check.each do |ou|
  filter = Net::LDAP::Filter.eq("ObjectClass", "user")
  treebase = "OU=#{ou},#{ENV['TREEBASE']}"

  ldap.search(:base => treebase, :filter => filter) do |entry|
    attributes = {}
    begin
      attributes[:mail] = entry.mail.join.downcase
    rescue NoMethodError => e
      if e.to_s.include? "mail"
        bad_user_entries << entry.name
        puts "The user #{entry.name} had no mail attribute assigned"
      else
        puts "Error Raised: #{e}"
      end
    end
    # Convert Windows NT Time to UNIX epoch time and add number of days until expiry to find expire time
    attributes[:PwdExpireTime] = Time.at(((entry.PwdLastSet.join.to_i)/10000000) - 11644473600) + expire_after.days
    users[entry.name.join] = attributes
  end
end

# Output All users for logging
puts "Found users: #{users}"

# Determine users with passwords about to expire
users.each do |user, attr|
  # Only include users with passwords that will expire in 5 days and up to 1 day past expiry
  if (-5..1).include?((Time.now - attr[:PwdExpireTime])/86400)
    users_to_notify[attr[:mail]] = {:PwdExpireTime => attr[:PwdExpireTime].strftime("%A, %d %b %Y %l:%M %p")}
  else
    puts "Will not notify #{user}, password expires in greater than 5 days: #{attr[:PwdExpireTime]}"
  end
end

## Slack
# Initialize Slack Connection
if !users_to_notify.empty?
  Slack.configure do |config|
    config.token = ENV['SLACK_API_TOKEN']
  end
  client = Slack::Web::Client.new
  # Find Slack usernames and add to hash
  slack_users = client.users_list.to_hash
  slack_users["members"].each do |user|
    if users_to_notify.include?(user["profile"]["email"].downcase)
      users_to_notify[user["profile"]["email"]][:slack_name] = user["name"]
    end
  end
  # Notify users and output user for logging
  users_to_notify.each do |user, attr|
    if !attr[:slack_name].nil?
      client.chat_postMessage(channel: "@#{attr[:slack_name]}", text: "Your Active Directory [e-mail] password will expire in less than 5 days at: #{attr[:PwdExpireTime]}. Reset your password by going to: #{ENV['PW_RESET_URL']}", as_user: true)
      puts "Notified #{user} with slack name: #{attr[:slack_name]} that their password will expire at #{attr[:PwdExpireTime]}"
    else
      client.chat_postMessage(channel: "##{ENV['BACKUP_SLACK_GROUP']}", text: "The AD password for #{user} will expire in less than 5 days at: #{attr[:PwdExpireTime]}. They do not have a slack account. Please notify them to reset their password by going to: #{ENV['PW_RESET_URL']}", as_user: true)
      puts "#{user} does not have a slack name, Sent a message to #{ENV['BACKUP_SLACK_GROUP']}"
    end
  end
  # Notify channel of users with missing mail attribute in AD
  if !bad_user_entries.empty?
    list = bad_user_entries.to_s.gsub(/"|\[|\]/, '')
    client.chat_postMessage(channel: "##{ENV["MISSING_ATTR_GROUP"]}", text: "The following user(s) do not have a mail attribute set in Active Directory: #{list}", as_user: true)
    puts "Slack group notified of users with missing mail attribute in Active Directory"
  end
end
