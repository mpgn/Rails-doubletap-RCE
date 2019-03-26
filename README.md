# Rails-doubletap-exploit

RCE on Rails 5.2.2 using a path traversal (CVE-2019-5418) and a deserialization of Ruby objects (CVE-2019-5420)

![capture d'écran](https://user-images.githubusercontent.com/5891788/54860812-dc7cc480-4d1f-11e9-8886-6d9c6a05d648.png)

**Technical Analysis**:
- CVE-2019-5418 - https://github.com/mpgn/CVE-2019-5418
- CVE-2019-5420 - https://hackerone.com/reports/473888


**Security Adivsory**:
- CVE-2019-5418 - https://groups.google.com/forum/#!topic/rubyonrails-security/pFRKI96Sm8Q
- CVE-2019-5420 - https://groups.google.com/forum/#!searchin/rubyonrails-security/CVE-2019-5420

---

### Exploit

1. The exploit check if the Rails application is vulnerable to the **CVE-2019-5418**
2. Then gets the content of the files: `credentials.yml.enc` and `master.key`
3. Decrypt the *credentials.yml.enc* and get the **secret_key_base** value
4. Craft a request to the resource `/rails/active_storage/disk/:encoded_key/*filename(.:format)` => **CVE-2019-5420**
5. Send the request to the vulnerable server
6. The code is executed on the server`

![capture d'écran_1](https://user-images.githubusercontent.com/5891788/54864755-f2a87600-4d5b-11e9-9eab-8402ea52c978.png)


---
Fix of **CVE-2019-5420**

```diff
From 7f5ccda38bfecbe0bf00f15e5b8f5e40d52ab3f1 Mon Sep 17 00:00:00 2001
From: Aaron Patterson <aaron.patterson@gmail.com>
Date: Sun, 10 Mar 2019 16:37:46 -0700
Subject: [PATCH] Fix possible dev mode RCE

If the secret_key_base is nil in dev or test generate a key from random
bytes and store it in a tmp file. This prevents the app developers from
having to share / checkin the secret key for dev / test but also
maintains a key between app restarts in dev/test.

[CVE-2019-5420]

Co-Authored-By: eileencodes <eileencodes@gmail.com>
Co-Authored-By: John Hawthorn <john@hawthorn.email>
---
 .../middleware/session/cookie_store.rb        |  7 +++---
 railties/lib/rails/application.rb             | 19 ++++++++++++++--
 .../test/application/configuration_test.rb    | 22 ++++++++++++++++++-
 railties/test/isolation/abstract_unit.rb      |  1 +
 4 files changed, 43 insertions(+), 6 deletions(-)

diff --git a/actionpack/lib/action_dispatch/middleware/session/cookie_store.rb b/actionpack/lib/action_dispatch/middleware/session/cookie_store.rb
index 4ea96196d3..b7475d3682 100644
--- a/actionpack/lib/action_dispatch/middleware/session/cookie_store.rb
+++ b/actionpack/lib/action_dispatch/middleware/session/cookie_store.rb
@@ -29,9 +29,10 @@
     #
     #   Rails.application.config.session_store :cookie_store, key: '_your_app_session'
     #
-    # By default, your secret key base is derived from your application name in
-    # the test and development environments. In all other environments, it is stored
-    # encrypted in the <tt>config/credentials.yml.enc</tt> file.
+    # In the development and test environments your application's secret key base is
+    # generated by Rails and stored in a temporary file in <tt>tmp/development_secret.txt</tt>.
+    # In all other environments, it is stored encrypted in the
+    # <tt>config/credentials.yml.enc</tt> file.
     #
     # If your application was not updated to Rails 5.2 defaults, the secret_key_base
     # will be found in the old <tt>config/secrets.yml</tt> file.
diff --git a/railties/lib/rails/application.rb b/railties/lib/rails/application.rb
index e346d5cc3a..6a30e8cfa0 100644
--- a/railties/lib/rails/application.rb
+++ b/railties/lib/rails/application.rb
@@ -426,8 +426,8 @@ def secrets=(secrets) #:nodoc:
     # then credentials.secret_key_base, and finally secrets.secret_key_base. For most applications,
     # the correct place to store it is in the encrypted credentials file.
     def secret_key_base
-      if Rails.env.test? || Rails.env.development?
-        secrets.secret_key_base || Digest::MD5.hexdigest(self.class.name)
+      if Rails.env.development? || Rails.env.test?
+        secrets.secret_key_base ||= generate_development_secret
       else
         validate_secret_key_base(
           ENV["SECRET_KEY_BASE"] || credentials.secret_key_base || secrets.secret_key_base
@@ -588,6 +588,21 @@ def validate_secret_key_base(secret_key_base)
 
     private
 
+      def generate_development_secret
+        if secrets.secret_key_base.nil?
+          key_file = Rails.root.join("tmp/development_secret.txt")
+
+          if !File.exist?(key_file)
+            random_key = SecureRandom.hex(64)
+            File.binwrite(key_file, random_key)
+          end
+
+          secrets.secret_key_base = File.binread(key_file)
+        end
+
+        secrets.secret_key_base
+      end
+
       def build_request(env)
         req = super
         env["ORIGINAL_FULLPATH"] = req.fullpath
diff --git a/railties/test/application/configuration_test.rb b/railties/test/application/configuration_test.rb
index 293a1a7dbd..68c2199aba 100644
--- a/railties/test/application/configuration_test.rb
+++ b/railties/test/application/configuration_test.rb
@@ -513,6 +513,27 @@ def index
     end
 
 
+    test "application will generate secret_key_base in tmp file if blank in development" do
+      app_file "config/initializers/secret_token.rb", <<-RUBY
+        Rails.application.credentials.secret_key_base = nil
+      RUBY
+
+      app "development"
+
+      assert_not_nil app.secrets.secret_key_base
+      assert File.exist?(app_path("tmp/development_secret.txt"))
+    end
+
+    test "application will not generate secret_key_base in tmp file if blank in production" do
+      app_file "config/initializers/secret_token.rb", <<-RUBY
+        Rails.application.credentials.secret_key_base = nil
+      RUBY
+
+      assert_raises ArgumentError do
+        app "production"
+      end
+    end
+
     test "raises when secret_key_base is blank" do
       app_file "config/initializers/secret_token.rb", <<-RUBY
         Rails.application.credentials.secret_key_base = nil
@@ -550,7 +571,6 @@ def index
 
     test "application verifier can build different verifiers" do
       make_basic_app do |application|
-        application.credentials.secret_key_base = "b3c631c314c0bbca50c1b2843150fe33"
         application.config.session_store :disabled
       end
 
diff --git a/railties/test/isolation/abstract_unit.rb b/railties/test/isolation/abstract_unit.rb
index 6568a356d6..fe850d45ec 100644
--- a/railties/test/isolation/abstract_unit.rb
+++ b/railties/test/isolation/abstract_unit.rb
@@ -155,6 +155,7 @@ def self.name; "RailtiesTestApp"; end
       @app.config.active_support.deprecation = :log
       @app.config.active_support.test_order = :random
       @app.config.log_level = :info
+      @app.secrets.secret_key_base = "b3c631c314c0bbca50c1b2843150fe33"
 
       yield @app if block_given?
       @app.initialize!
-- 
2.21.0
```

Fix of **CVE-2019-5418**
```diff
From d7fac9c09a535ec7f11bb9aa8addb4af37b7d4b5 Mon Sep 17 00:00:00 2001
From: John Hawthorn <john@hawthorn.email>
Date: Mon, 4 Mar 2019 18:24:51 -0800
Subject: [PATCH] Only accept formats from registered mime types

[CVE-2019-5418]
[CVE-2019-5419]
---
 .../lib/action_dispatch/http/mime_negotiation.rb   |  5 +++++
 actionpack/test/controller/mime/respond_to_test.rb | 10 ++++++----
 .../new_base/content_negotiation_test.rb           | 14 ++++++++++++--
 3 files changed, 23 insertions(+), 6 deletions(-)

diff --git a/actionpack/lib/action_dispatch/http/mime_negotiation.rb b/actionpack/lib/action_dispatch/http/mime_negotiation.rb
index d7435fa8df..ada52adfeb 100644
--- a/actionpack/lib/action_dispatch/http/mime_negotiation.rb
+++ b/actionpack/lib/action_dispatch/http/mime_negotiation.rb
@@ -74,6 +74,11 @@ def formats
           else
             [Mime[:html]]
           end
+
+          v = v.select do |format|
+            format.symbol || format.ref == "*/*"
+          end
+
           set_header k, v
         end
       end
diff --git a/actionpack/test/controller/mime/respond_to_test.rb b/actionpack/test/controller/mime/respond_to_test.rb
index f9ffd5f54c..a80cef83b7 100644
--- a/actionpack/test/controller/mime/respond_to_test.rb
+++ b/actionpack/test/controller/mime/respond_to_test.rb
@@ -105,7 +105,7 @@ def made_for_content_type
   def custom_type_handling
     respond_to do |type|
       type.html { render body: "HTML"    }
-      type.custom("application/crazy-xml")  { render body: "Crazy XML"  }
+      type.custom("application/fancy-xml")  { render body: "Fancy XML"  }
       type.all  { render body: "Nothing" }
     end
   end
@@ -294,12 +294,14 @@ def setup
     @request.host = "www.example.com"
     Mime::Type.register_alias("text/html", :iphone)
     Mime::Type.register("text/x-mobile", :mobile)
+    Mime::Type.register("application/fancy-xml", :fancy_xml)
   end
 
   def teardown
     super
     Mime::Type.unregister(:iphone)
     Mime::Type.unregister(:mobile)
+    Mime::Type.unregister(:fancy_xml)
   end
 
   def test_html
@@ -455,10 +457,10 @@ def test_synonyms
   end
 
   def test_custom_types
-    @request.accept = "application/crazy-xml"
+    @request.accept = "application/fancy-xml"
     get :custom_type_handling
-    assert_equal "application/crazy-xml", @response.content_type
-    assert_equal "Crazy XML", @response.body
+    assert_equal "application/fancy-xml", @response.content_type
+    assert_equal "Fancy XML", @response.body
 
     @request.accept = "text/html"
     get :custom_type_handling
diff --git a/actionpack/test/controller/new_base/content_negotiation_test.rb b/actionpack/test/controller/new_base/content_negotiation_test.rb
index 7205e90176..6de91c57b7 100644
--- a/actionpack/test/controller/new_base/content_negotiation_test.rb
+++ b/actionpack/test/controller/new_base/content_negotiation_test.rb
@@ -20,9 +20,19 @@ def all
       assert_body "Hello world */*!"
     end
 
-    test "Not all mimes are converted to symbol" do
+    test "A js or */* Accept header will return HTML" do
+      get "/content_negotiation/basic/hello", headers: { "HTTP_ACCEPT" => "text/javascript, */*" }
+      assert_body "Hello world text/html!"
+    end
+
+    test "A js or */* Accept header on xhr will return HTML" do
+      get "/content_negotiation/basic/hello", headers: { "HTTP_ACCEPT" => "text/javascript, */*" }, xhr: true
+      assert_body "Hello world text/javascript!"
+    end
+
+    test "Unregistered mimes are ignored" do
       get "/content_negotiation/basic/all", headers: { "HTTP_ACCEPT" => "text/plain, mime/another" }
-      assert_body '[:text, "mime/another"]'
+      assert_body '[:text]'
     end
   end
 end
-- 
2.21.0
```
