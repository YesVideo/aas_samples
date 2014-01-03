aas_samples
===========

This repository contains sample client code for working with [YesVideo Archive as a Service](https://aas.yesvideo.com).  Before using these samples, you should read the [API documentation](https://aas.yesvideo.com/docs).  You will also need to have signed up for an account in order to obtain API credentials.

# Ruby samples #

Run `bundle install` in the `ruby` directory to install required gems.

`aas_sdk.rb` provides simple Ruby wrappers around the AAS API.  See [here for sdk docs](http://rubydoc.info/github/YesVideo/aas_samples/master/frames).

`aas_cmd` is a simple Ruby script that uses the SDK to list and upload collections and create orders.

Sample usage:

    # get help
    aas_cmd -h
    
    # specify AAS client_id and secret as options or as env vars
    export AAS_CLIENT_ID=<your_client_id>
    export AAS_SECRET=<your_secret>

    # create a collection
    aas_cmd create_collection -t dvd_4_7G
    
    # list collections
    aas_cmd collections
    
    # upload files to a collection
    # aas_cmd upload -c <collection_id> <files_or_directories_to_upload>...
    aas_cmd upload -c 52c5fb14fd9a5c3da1000176 directory1 directory2 file1 file2
    
    # list files in a collection
    aas_cmd files -c 52c5fb14fd9a5c3da1000176
    
    # create a new order
    aas_cmd burn -c 52c5fb14fd9a5c3da1000176 --title "My DVD" --recipient "Joe Smith" --address1 "1 Main St." --city "San Francisco" --state "CA" --postal-code "94111" --phone-number "415 555 1212"
    
    # list orders
    aas_cmd orders