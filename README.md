aas_samples
===========

This repository contains sample client code for working with [YesVideo Archive as a Service](https://aas.yesvideo.com).  Before using these samples, you should read the [API documentation](https://aas.yesvideo.com/docs).  You will also need to have signed up for an account in order to obtain API credentials.

# Ruby samples #

Run `bundle install` in the `ruby` directory to install required gems.

`aas_sdk.rb` provides simple Ruby wrappers around the AAS API.  See [here for sdk docs](http://rubydoc.info/github/YesVideo/aas_samples/master/frames) (via yardoc).

`aas_cmd` is a simple Ruby script that uses the SDK to list and upload collections and create orders.