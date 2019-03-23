class DemoController < ApplicationController
  def index
	  render file: "#{Rails.root}/../README.md"
  end
end
