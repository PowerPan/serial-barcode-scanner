/* Copyright 2012, Sebastian Reichel <sre@ring0.de>
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

public const int day_in_seconds = 24*60*60;

public struct StockEntry {
	public string id;
	public string name;
	public int amount;
	public string memberprice;
	public string guestprice;
}

public struct PriceEntry {
	public int64 valid_from;
	public Price memberprice;
	public Price guestprice;
}

public struct RestockEntry {
	public int64 timestamp;
	public int amount;
	public string price;
}

public struct UserInfo {
	public int id;
	public string firstname;
	public string lastname;
	public string email;
	public string gender;
	public string street;
	public int postcode;
	public string city;

	public bool equals(UserInfo x) {
		if(id != x.id) return false;
		if(firstname != x.firstname) return false;
		if(lastname != x.lastname) return false;
		if(email != x.email) return false;
		if(gender != x.gender) return false;
		if(street != x.street) return false;
		if(postcode != x.postcode) return false;
		if(city != x.city) return false;

		return true;
	}

	public bool exists_in_db() {
		if(id in db.get_member_ids())
			return true;
		else
			return false;
	}

	public bool equals_db() {
		return this.equals(db.get_user_info(id));
	}
}

public struct UserAuth {
	public int id;
	public bool disabled;
	public bool superuser;
}

public struct Product {
	public uint64 ean;
	public string name;
}

public struct InvoiceEntry {
	public int64 timestamp;
	Product product;
	Price price;
}

public struct StatsInfo {
	public int count_articles;
	public int count_users;
	public Price stock_value;
	public Price sales_total;
	public Price profit_total;
	public Price sales_today;
	public Price profit_today;
	public Price sales_this_month;
	public Price profit_this_month;
	public Price sales_per_day;
	public Price profit_per_day;
	public Price sales_per_month;
	public Price profit_per_month;
}

public class Database {
	private class Statement {
		private Sqlite.Statement stmt;

		public Statement(Sqlite.Database db, string query) {
			int rc = db.prepare_v2(query, -1, out stmt);

			if(rc != Sqlite.OK) {
				error("could not prepare statement: %s", query);
			}
		}

		public void reset() {
			stmt.reset();
		}

		public int step() {
			return stmt.step();
		}

		public int bind_int(int index, int value) {
			return stmt.bind_int(index, value);
		}

		public int bind_text(int index, string value) {
			return stmt.bind_text(index, value);
		}

		public int bind_int64(int index, int64 value) {
			return stmt.bind_int64(index, value);
		}

		public int column_int(int index) {
			return stmt.column_int(index);
		}

		public string column_text(int index) {
			return stmt.column_text(index);
		}

		public int64 column_int64(int index) {
			return stmt.column_int64(index);
		}
	}

	private Sqlite.Database db;
	private static Gee.HashMap<string,string> queries = new Gee.HashMap<string,string>();
	private static Gee.HashMap<string,Statement> statements = new Gee.HashMap<string,Statement>();

	int32 user = 0;
	bool logged_in = false;

	public Database(string file) {
		int rc;

		rc = Sqlite.Database.open(file, out db);
		if(rc != Sqlite.OK) {
			error("could not open database!");
		}

		/* setup queries */
		queries["product_name"]      = "SELECT name FROM products WHERE id = ?";
		queries["product_amount"]    = "SELECT amount FROM products WHERE id = ?";
		queries["products"]          = "SELECT id, name, amount FROM products ORDER BY name";
		queries["purchase"]          = "INSERT INTO sells ('user', 'product', 'timestamp') VALUES (?, ?, ?)";
		queries["last_purchase"]     = "SELECT product FROM sells WHERE user = ? ORDER BY timestamp DESC LIMIT 1";
		queries["undo"]              = "DELETE FROM sells WHERE user = ? ORDER BY timestamp DESC LIMIT 1";
		queries["product_create"]    = "INSERT INTO products ('id', 'name', 'amount') VALUES (?, ?, ?)";
		queries["price_create"]      = "INSERT INTO prices ('product', 'valid_from', 'memberprice', 'guestprice') VALUES (?, ?, ?, ?)";
		queries["stock"]             = "INSERT INTO restock ('user', 'product', 'amount', 'price', 'timestamp') VALUES (?, ?, ?, ?, ?)";
		queries["price"]             = "SELECT memberprice, guestprice FROM prices WHERE product = ? AND valid_from <= ? ORDER BY valid_from DESC LIMIT 1";
		queries["prices"]            = "SELECT valid_from, memberprice, guestprice FROM prices WHERE product = ? ORDER BY valid_from ASC;";
		queries["restocks"]          = "SELECT timestamp, amount, price FROM restock WHERE product = ? ORDER BY timestamp ASC;";
		queries["profit_complex"]    = "SELECT SUM(memberprice - (SELECT price FROM purchaseprices WHERE product = purch.product)) FROM sells purch, prices WHERE purch.product = prices.product AND purch.user > 0 AND purch.timestamp > ? AND purch.timestamp < ? AND prices.valid_from = (SELECT valid_from FROM prices WHERE product = purch.product AND valid_from < purch.timestamp ORDER BY valid_from DESC LIMIT 1);";
		queries["sales_complex"]     = "SELECT SUM(memberprice) FROM sells purch, prices WHERE purch.product = prices.product AND purch.user > 0 AND purch.timestamp > ? AND purch.timestamp < ? AND prices.valid_from = (SELECT valid_from FROM prices WHERE product = purch.product AND valid_from < purch.timestamp ORDER BY valid_from DESC LIMIT 1);";
		queries["stock_status"]      = "SELECT id, name, amount, memberprice, guestprice FROM products, prices WHERE products.id = prices.product AND prices.valid_from = (SELECT valid_from FROM prices WHERE product = products.id ORDER BY valid_from DESC LIMIT 1) ORDER BY name";
		queries["stock_amount"]      = "SELECT timestamp, amount FROM restock WHERE product = ? UNION ALL SELECT timestamp, -1 AS amount FROM sells WHERE product = ? ORDER BY timestamp DESC";
		queries["session_set"]       = "UPDATE authentication SET session=? WHERE user = ?";
		queries["session_get"]       = "SELECT user FROM authentication WHERE session = ?";
		queries["username"]          = "SELECT firstname, lastname FROM users WHERE id = ?";
		queries["password_get"]      = "SELECT password FROM authentication WHERE user = ?";
		queries["userinfo"]          = "SELECT firstname, lastname, email, gender, street, plz, city FROM users WHERE id = ?";
		queries["userauth"]          = "SELECT disabled, superuser FROM authentication WHERE user = ?";
		queries["profit_by_product"] = "SELECT name, SUM(memberprice - (SELECT price FROM purchaseprices WHERE product = purch.product)) AS price FROM sells purch, prices, products WHERE purch.product = products.id AND purch.product = prices.product AND purch.user > 0 AND purch.timestamp > ? AND purch.timestamp < ? AND prices.valid_from = (SELECT valid_from FROM prices WHERE product = purch.product AND valid_from < purch.timestamp ORDER BY valid_from DESC LIMIT 1) GROUP BY name ORDER BY price;";
		queries["invoice"]           = "SELECT timestamp, productid, productname, price FROM invoice WHERE user = ? AND timestamp >= ? AND timestamp < ?;";
		queries["purchase_first"]    = "SELECT timestamp FROM sells WHERE user = ? ORDER BY timestamp ASC  LIMIT 1";
		queries["purchase_last"]     = "SELECT timestamp FROM sells WHERE user = ? ORDER BY timestamp DESC LIMIT 1";
		queries["count_articles"]    = "SELECT COUNT(*) FROM products";
		queries["count_users"]       = "SELECT COUNT(*) FROM users";
		queries["stock_value"]       = "SELECT SUM(amount * price) FROM products INNER JOIN purchaseprices ON products.id = purchaseprices.product";
		queries["total_sales"]       = "SELECT SUM(price) FROM invoice WHERE user >= 0 AND timestamp >= ?";
		queries["total_profit"]      = "SELECT SUM(price - (SELECT price FROM purchaseprices WHERE product = productid)) FROM invoice WHERE user >= 0 AND timestamp >= ?";
		queries["user_get_ids"]      = "SELECT id FROM users WHERE id > 0";
		queries["user_replace"]      = "INSERT OR REPLACE INTO users ('id', 'email', 'firstname', 'lastname', 'gender', 'street', 'plz', 'city') VALUES (?, ?, ?, ?, ?, ?, ?, ?)";
		queries["user_auth_create"]	 = "INSERT OR IGNORE INTO authentication (user) VALUES (?)";
		queries["user_disable"]		 = "UPDATE authentication SET disabled = ? WHERE user = ?";

		/* compile queries into statements */
		foreach(var entry in queries.entries) {
			statements[entry.key] = new Statement(db, entry.value);
		}
	}

	public bool login(int32 id) {
		this.user = id;
		this.logged_in = true;
		return true;
	}

	public bool logout() {
		this.user = 0;
		this.logged_in = false;
		return true;
	}

	public Gee.HashMap<string,string> get_products() {
		var result = new Gee.HashMap<string,string>(null, null);
		statements["products"].reset();

		while(statements["products"].step() == Sqlite.ROW)
			result[statements["products"].column_text(0)] = statements["products"].column_text(1);

		return result;
	}

	public stock get_stats_stock() {
		var result = new stock();
		var now = time_t();

		/* init products */
		statements["products"].reset();
		while(statements["products"].step() == Sqlite.ROW) {
			var id = uint64.parse(statements["products"].column_text(0));
			var name = statements["products"].column_text(1);
			int amount = int.parse(statements["products"].column_text(2));
			var product = new stock.product(id, name);
			result.add(product);
			product.add(now, amount);

			statements["stock_amount"].reset();
			statements["stock_amount"].bind_text(1, "%llu".printf(id));
			statements["stock_amount"].bind_text(2, "%llu".printf(id));

			while(statements["stock_amount"].step() == Sqlite.ROW) {
				var timestamp = uint64.parse(statements["stock_amount"].column_text(0));
				var diff = statements["stock_amount"].column_int(1);
				product.add(timestamp+1, amount);
				amount -= diff;
				product.add(timestamp, amount);
			}
		}

		return result;
	}

	public profit_per_product get_stats_profit_per_products() {
		var result = new profit_per_product();

		statements["profit_by_product"].reset();
		statements["profit_by_product"].bind_int(1, 0);
		statements["profit_by_product"].bind_text(2, "99999999999999");

		while(statements["profit_by_product"].step() == Sqlite.ROW) {
			var name = statements["profit_by_product"].column_text(0);
			var profit = statements["profit_by_product"].column_int(1);
			result.add(name, profit);
		}

		return result;
	}

	public profit_per_weekday get_stats_profit_per_weekday() {
		var result = new profit_per_weekday();

		var now = new DateTime.now_utc();
		var today = new DateTime.utc(now.get_year(), now.get_month(), now.get_day_of_month(), 8, 0, 0);
		var tomorrow = today.add_days(1);
		var weekday = tomorrow.get_day_of_week()-1;

		var to   = tomorrow.to_unix();
		var from = to - day_in_seconds;

		var weeks = 8;

		for(int i=0; i<weeks*7; i++) {
			statements["profit_complex"].reset();
			statements["profit_complex"].bind_text(1, "%llu".printf(from));
			statements["profit_complex"].bind_text(2, "%llu".printf(to));

			if(statements["profit_complex"].step() == Sqlite.ROW)
				result.day[weekday] += statements["profit_complex"].column_int(0);

			from-=day_in_seconds;
			to-=day_in_seconds;
			weekday = (weekday + 1) % 7;
		}

		for(int i=0; i<7; i++)
			result.day[i] /= weeks;

		return result;
	}

	public profit_per_day get_stats_profit_per_day() {
		var result = new profit_per_day();
		var to   = time_t();
		var from = to - day_in_seconds;

		/* 8 weeks */
		for(int i=0; i<8*7; i++) {
			statements["profit_complex"].reset();
			statements["profit_complex"].bind_text(1, "%llu".printf(from));
			statements["profit_complex"].bind_text(2, "%llu".printf(to));
			statements["sales_complex"].reset();
			statements["sales_complex"].bind_text(1, "%llu".printf(from));
			statements["sales_complex"].bind_text(2, "%llu".printf(to));


			if(statements["profit_complex"].step() == Sqlite.ROW)
				result.add_profit(from, statements["profit_complex"].column_int(0));
			if(statements["sales_complex"].step() == Sqlite.ROW)
				result.add_sales(from, statements["sales_complex"].column_int(0));

			from-=day_in_seconds;
			to-=day_in_seconds;
		}

		return result;
	}

	public Gee.List<StockEntry?> get_stock() {
		var result = new Gee.ArrayList<StockEntry?>();
		statements["stock_status"].reset();

		while(statements["stock_status"].step() == Sqlite.ROW) {
			StockEntry entry = {
				statements["stock_status"].column_text(0),
				statements["stock_status"].column_text(1),
				statements["stock_status"].column_int(2),
				null,
				null
			};

			Price mprice = statements["stock_status"].column_int(3);
			Price gprice = statements["stock_status"].column_int(4);

			entry.memberprice = @"$mprice";
			entry.guestprice  = @"$gprice";

			result.add(entry);
		}

		return result;
	}

	public Gee.List<PriceEntry?> get_prices(uint64 product) {
		var result = new Gee.ArrayList<PriceEntry?>();
		statements["prices"].reset();
		statements["prices"].bind_text(1, "%llu".printf(product));

		while(statements["prices"].step() == Sqlite.ROW) {
			PriceEntry entry = {
				statements["prices"].column_int64(0),
				statements["prices"].column_int(1),
				statements["prices"].column_int(2)
			};

			result.add(entry);
		}

		return result;
	}

	public Gee.List<RestockEntry?> get_restocks(uint64 product) {
		var result = new Gee.ArrayList<RestockEntry?>();
		statements["restocks"].reset();
		statements["restocks"].bind_text(1, "%llu".printf(product));

		while(statements["restocks"].step() == Sqlite.ROW) {
			RestockEntry entry = {
				statements["restocks"].column_int64(0),
				statements["restocks"].column_int(1)
			};

			Price p = statements["restocks"].column_int(2);
			entry.price = @"$p";

			result.add(entry);
		}

		return result;
	}

	public bool buy(uint64 article) {
		if(is_logged_in()) {
			int rc = 0;
			int64 timestamp = (new DateTime.now_utc()).to_unix();

			statements["purchase"].reset();
			statements["purchase"].bind_text(1, "%d".printf(user));
			statements["purchase"].bind_text(2, "%llu".printf(article));
			statements["purchase"].bind_text(3, "%llu".printf(timestamp));

			rc = statements["purchase"].step();
			if(rc != Sqlite.DONE)
				error("[internal error: %d]".printf(rc));

			return true;
		} else {
			return false;
		}
	}

	public string get_product_name(uint64 article) {
		statements["product_name"].reset();
		statements["product_name"].bind_text(1, "%llu".printf(article));

		int rc = statements["product_name"].step();

		switch(rc) {
			case Sqlite.ROW:
				return statements["product_name"].column_text(0);
			case Sqlite.DONE:
				return "unbekanntes Produkt: %llu".printf(article);
			default:
				return "[internal error: %d]".printf(rc);
		}
	}

	public int get_product_amount(uint64 article) {
		statements["product_amount"].reset();
		statements["product_amount"].bind_text(1, "%llu".printf(article));

		int rc = statements["product_amount"].step();

		switch(rc) {
			case Sqlite.ROW:
				return statements["product_amount"].column_int(0);
			case Sqlite.DONE:
				warning("unbekanntes Produkt: %llu".printf(article));
				return -1;
			default:
				warning("[internal error: %d]".printf(rc));
				return -1;
		}
	}

	public int get_product_price(uint64 article) {
		int64 timestamp = (new DateTime.now_utc()).to_unix();
		bool member = user != 0;

		statements["price"].reset();
		statements["price"].bind_text(1, "%llu".printf(article));
		statements["price"].bind_text(2, "%lld".printf(timestamp));

		int rc = statements["price"].step();

		switch(rc) {
			case Sqlite.ROW:
				if(member)
					return statements["price"].column_int(0);
				else
					return statements["price"].column_int(1);
			case Sqlite.DONE:
				write_to_log("unbekanntes Produkt: %llu\n", article);
				return 0;
			default:
				write_to_log("[internal error: %d]\n", rc);
				return 0;
		}
	}

	public bool undo() {
		if(is_logged_in()) {
			uint64 pid = 0;
			int rc = 0;

			statements["last_purchase"].reset();
			statements["last_purchase"].bind_text(1, "%d".printf(user));

			rc = statements["last_purchase"].step();
			switch(rc) {
				case Sqlite.ROW:
					pid = uint64.parse(statements["last_purchase"].column_text(0));
					write_to_log("remove purchase of %llu", pid);
					break;
				case Sqlite.DONE:
					write_to_log("undo not possible without purchases");
					return false;
				default:
					error("[internal error: %d]".printf(rc));
			}

			statements["undo"].reset();
			statements["undo"].bind_text(1, "%d".printf(user));

			rc = statements["undo"].step();
			if(rc != Sqlite.DONE)
				error("[internal error: %d]".printf(rc));

			return true;
		}

		return false;
	}

	public bool restock(int user, uint64 product, uint amount, uint price) {
		if(user > 0) {
			int rc = 0;
			int64 timestamp = (new DateTime.now_utc()).to_unix();

			statements["stock"].reset();
			statements["stock"].bind_int(1, user);
			statements["stock"].bind_text(2, @"$product");
			statements["stock"].bind_text(3, @"$amount");
			statements["stock"].bind_text(4, @"$price");
			statements["stock"].bind_int64(5, timestamp);

			rc = statements["stock"].step();
			if(rc != Sqlite.DONE)
				error("[internal error: %d]".printf(rc));

			return true;
		}

		return false;
	}

	public bool new_product(uint64 id, string name, int memberprice, int guestprice) {
		statements["product_create"].reset();
		statements["product_create"].bind_text(1, @"$id");
		statements["product_create"].bind_text(2, name);
		statements["product_create"].bind_int(3, 0);
		int rc = statements["product_create"].step();

		if(rc != Sqlite.DONE) {
			warning("[internal error: %d]".printf(rc));
			return false;
		}

		return new_price(id, 0, memberprice, guestprice);
	}

	public bool new_price(uint64 product, int64 timestamp, int memberprice, int guestprice) {
		statements["price_create"].reset();
		statements["price_create"].bind_text(1, @"$product");
		statements["price_create"].bind_int64(2, timestamp);
		statements["price_create"].bind_int(3, memberprice);
		statements["price_create"].bind_int(4, guestprice);
		int rc = statements["price_create"].step();

		if(rc != Sqlite.DONE) {
			warning("[internal error: %d]".printf(rc));
			return false;
		}

		return true;
	}

	public bool is_logged_in() {
		return this.logged_in;
	}

	public bool check_user_password(int32 user, string password) {
		statements["password_get"].reset();
		statements["password_get"].bind_int(1, user);

		if(statements["password_get"].step() == Sqlite.ROW) {
			var pwhash_db = statements["password_get"].column_text(0);
			var pwhash_user = Checksum.compute_for_string(ChecksumType.SHA256, password);

			stdout.printf("tried login: %s\n", pwhash_user);

			return pwhash_db == pwhash_user;
		} else {
			return false;
		}
	}

	public void set_sessionid(int user, string sessionid) {
		statements["session_set"].reset();
		statements["session_set"].bind_text(1, sessionid);
		statements["session_set"].bind_int(2, user);

		int rc = statements["session_set"].step();
		if(rc != Sqlite.DONE)
			error("[internal error: %d]".printf(rc));
	}

	public int get_user_by_sessionid(string sessionid) throws WebSessionError {
		statements["session_get"].reset();
		statements["session_get"].bind_text(1, sessionid);

		if(statements["session_get"].step() == Sqlite.ROW) {
			return statements["session_get"].column_int(0);
		} else {
			throw new WebSessionError.SESSION_NOT_FOUND("No such session available in database!");
		}
	}

	public UserInfo get_user_info(int user) {
		var result = UserInfo();
		statements["userinfo"].reset();
		statements["userinfo"].bind_int(1, user);

		if(statements["userinfo"].step() == Sqlite.ROW) {
			result.id = user;
			result.firstname = statements["userinfo"].column_text(0);
			result.lastname  = statements["userinfo"].column_text(1);
			result.email     = statements["userinfo"].column_text(2);
			result.gender    = statements["userinfo"].column_text(3);
			result.street    = statements["userinfo"].column_text(4);
			result.postcode  = statements["userinfo"].column_int(5);
			result.city      = statements["userinfo"].column_text(6);
		}

		return result;
	}

	public UserAuth get_user_auth(int user) {
		var result = UserAuth();
		result.id = user;
		result.disabled = false;
		result.superuser = false;

		statements["userauth"].reset();
		statements["userauth"].bind_int(1, user);
		if(statements["userauth"].step() == Sqlite.ROW) {
			result.disabled  = statements["userauth"].column_int(0) == 1;
			result.superuser = statements["userauth"].column_int(1) == 1;
		}

		return result;
	}

	public string get_username(int user) throws WebSessionError {
		statements["username"].reset();
		statements["username"].bind_int(1, user);

		if(statements["username"].step() == Sqlite.ROW) {
			return statements["username"].column_text(0)+" "+statements["username"].column_text(1);
		} else {
			throw new WebSessionError.USER_NOT_FOUND("No such user available in database!");
		}
	}

	public Gee.List<InvoiceEntry?> get_invoice(int user, int64 from=0, int64 to=-1) {
		var result = new Gee.ArrayList<InvoiceEntry?>();

		if(to == -1) {
			to = time_t();
		}

		statements["invoice"].reset();
		statements["invoice"].bind_int(1, user);
		statements["invoice"].bind_int64(2, from);
		statements["invoice"].bind_int64(3, to);

		while(statements["invoice"].step() == Sqlite.ROW) {
			InvoiceEntry entry = {};
			entry.timestamp = statements["invoice"].column_int64(0);
			entry.product.ean = uint64.parse(statements["invoice"].column_text(1));
			entry.product.name = statements["invoice"].column_text(2);
			entry.price = statements["invoice"].column_int(3);
			result.add(entry);
		}

		return result;
	}

	public DateTime get_first_purchase(int user) {
		statements["purchase_first"].reset();
		statements["purchase_first"].bind_int(1, user);

		if(statements["purchase_first"].step() == Sqlite.ROW)
			return new DateTime.from_unix_utc(statements["purchase_first"].column_int64(0));
		else
			return new DateTime.from_unix_utc(0);
	}

	public DateTime get_last_purchase(int user) {
		statements["purchase_last"].reset();
		statements["purchase_last"].bind_int(1, user);

		if(statements["purchase_last"].step() == Sqlite.ROW)
			return new DateTime.from_unix_utc(statements["purchase_last"].column_int64(0));
		else
			return new DateTime.from_unix_utc(0);
	}

	public StatsInfo get_stats_info() {
		var result = StatsInfo();

		DateTime now = new DateTime.now_local();
		DateTime today = new DateTime.local(now.get_year(), now.get_month(), now.get_hour() < 8 ? now.get_day_of_month()-1 : now.get_day_of_month(), 8, 0, 0);
		DateTime month = new DateTime.local(now.get_year(), now.get_day_of_month() < 16 ? now.get_month()-1 : now.get_month(), 16, 8, 0, 0);

		DateTime last4weeks = now.add_days(-28);
		DateTime last4months = now.add_months(-4);

		statements["count_articles"].reset();
		if(statements["count_articles"].step() == Sqlite.ROW)
			result.count_articles = statements["count_articles"].column_int(0);

		statements["count_users"].reset();
		if(statements["count_users"].step() == Sqlite.ROW)
			result.count_users = statements["count_users"].column_int(0);

		statements["stock_value"].reset();
		if(statements["stock_value"].step() == Sqlite.ROW)
			result.stock_value = statements["stock_value"].column_int(0);

		statements["total_sales"].reset();
		statements["total_sales"].bind_int64(1, 0);
		if(statements["total_sales"].step() == Sqlite.ROW)
			result.sales_total = statements["total_sales"].column_int(0);

		statements["total_profit"].reset();
		statements["total_profit"].bind_int64(1, 0);
		if(statements["total_profit"].step() == Sqlite.ROW)
			result.profit_total = statements["total_profit"].column_int(0);

		statements["total_sales"].reset();
		statements["total_sales"].bind_int64(1, today.to_unix());
		if(statements["total_sales"].step() == Sqlite.ROW)
			result.sales_today = statements["total_sales"].column_int(0);

		statements["total_profit"].reset();
		statements["total_profit"].bind_int64(1, today.to_unix());
		if(statements["total_profit"].step() == Sqlite.ROW)
			result.profit_today = statements["total_profit"].column_int(0);

		statements["total_sales"].reset();
		statements["total_sales"].bind_int64(1, month.to_unix());
		if(statements["total_sales"].step() == Sqlite.ROW)
			result.sales_this_month = statements["total_sales"].column_int(0);

		statements["total_profit"].reset();
		statements["total_profit"].bind_int64(1, month.to_unix());
		if(statements["total_profit"].step() == Sqlite.ROW)
			result.profit_this_month = statements["total_profit"].column_int(0);

		statements["total_sales"].reset();
		statements["total_sales"].bind_int64(1, last4weeks.to_unix());
		if(statements["total_sales"].step() == Sqlite.ROW)
			result.sales_per_day = statements["total_sales"].column_int(0) / 28;

		statements["total_profit"].reset();
		statements["total_profit"].bind_int64(1, last4weeks.to_unix());
		if(statements["total_profit"].step() == Sqlite.ROW)
			result.profit_per_day = statements["total_profit"].column_int(0) / 28;

		statements["total_sales"].reset();
		statements["total_sales"].bind_int64(1, last4months.to_unix());
		if(statements["total_sales"].step() == Sqlite.ROW)
			result.sales_per_month = statements["total_sales"].column_int(0) / 4;

		statements["total_profit"].reset();
		statements["total_profit"].bind_int64(1, last4months.to_unix());
		if(statements["total_profit"].step() == Sqlite.ROW)
			result.profit_per_month = statements["total_profit"].column_int(0) / 4;

		return result;
	}

	public Gee.List<int> get_member_ids() {
		var result = new Gee.ArrayList<int>();

		statements["user_get_ids"].reset();
		while(statements["user_get_ids"].step() == Sqlite.ROW)
			result.add(statements["user_get_ids"].column_int(0));

		return result;
	}

	public void user_disable(int user, bool value) {
		int rc;

		/* create user auth line if not existing */
		statements["user_auth_create"].reset();
		statements["user_auth_create"].bind_int(1, user);
		rc = statements["user_auth_create"].step();
		if(rc != Sqlite.DONE)
			error("[internal error: %d]".printf(rc));

		/* set disabled flag */
		statements["user_disable"].reset();
		statements["user_disable"].bind_int(1, value ? 1 : 0);
		statements["user_disable"].bind_int(2, user);
		rc = statements["user_disable"].step();
		if(rc != Sqlite.DONE)
			error("[internal error: %d]".printf(rc));
	}

	public void user_replace(UserInfo u) {
		statements["user_replace"].reset();
		statements["user_replace"].bind_int(1, u.id);
		statements["user_replace"].bind_text(2, u.email);
		statements["user_replace"].bind_text(3, u.firstname);
		statements["user_replace"].bind_text(4, u.lastname);
		statements["user_replace"].bind_text(5, u.gender);
		statements["user_replace"].bind_text(6, u.street);
		statements["user_replace"].bind_int(7, u.postcode);
		statements["user_replace"].bind_text(8, u.city);

		int rc = statements["user_replace"].step();
		if(rc != Sqlite.DONE)
			error("[internal error: %d]".printf(rc));
	}

	public bool user_is_disabled(int user) {
		return get_user_auth(user).disabled;
	}
}