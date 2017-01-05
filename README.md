# ad_pass_bot
Notify users on Slack when their AD password is going to expire

## Usage

- Clone this repo and create your `.env`

  ```
  $ git clone git@github.com:jshapiro26/ad_pass_bot.git
  $ cd ad_pass_bot && cp .env_sample .env
  ```

- Fill out your variables for each entry in the `.env` file

  ```
  $ docker pull jshapiro26/ad_pass_bot
  $ docker run -v $(pwd)/.env:/opt/ad_pass_bot/.env jshapiro26/ad_pass_bot
  ```

- You can put this `docker run` command on a daily cron to automate it.