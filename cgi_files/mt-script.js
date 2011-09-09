// <script language="JavaScript" type="text/javascript">

// note that we cuddle our elses in here, this is required for some 
// browsers according to: http://en.wikipedia.org/wiki/JavaScript_syntax

var mailhost = 'https://mail.example.com';

/*  If you want a default webmail application launched when a user
    clicks on "webmail", then set this value to the name of the 
    webmail application as shown in the launch_selected_web_app
    function below. */
    
// var default_webmail = "squirrel";
// var default_webmail = "roundcube";
var default_webmail = "windex";    // the webmail index page

/*  A default destination for the "admin" link. Since the most common
    admin function will be in qmailadmin, that is the default. You can
    simply remove qmailadmin and leave a double quoted empty string 
    there ("") instead. The same applies for statistics. */

var default_admin      = "qmailadmin";
var default_statistics = "munin";

// these color selectors determine the color of elements updated

var active_background_color  = "#cccc99";      // active links color
var primary_background_color = "#FFFFCC";      // page background color
var primary_background_image = "url('images/tan-50-opaque.gif')";

var active_text_color  = "#666666";   // light grey
var primary_text_color = "#333333";   // darker grey

function selectHeading(showme, webApp) {

	var styleObject = ""
	var top_divs = new Array("admin", "webmail", "help", "stats");
	
	// reset all the background URLs to off
	resetTopBackgrounds();

	switch ( showme ) {
	    case "webmail":
			getStyleObject('webmail_span').background = "url('images/mt_tab-left-on.gif')";
			getStyleObject('admin_span').background = "url('images/mt_tab-middle-off-lefton.gif')";
            if ( !  auth_valid() ) {
                return false;
            };
			showThis(showme);
			break;
	    case "admin":
            if ( ! auth_valid() ) {
                return false;
            }
			showThis(showme);
			getStyleObject('admin_span').background = "url('images/mt_tab-middle-on.gif')";
			getStyleObject('stats_span').background = "url('images/mt_tab-middle-off-lefton.gif')";
			break;
	    case "stats":
			getStyleObject('stats_span').background = "url('images/mt_tab-middle-on.gif')";
			getStyleObject('help_span').background = "url('images/mt_tab-middle-off-lefton.gif')";
			break;
	    case "help":
			getStyleObject('help_span').background = "url('images/mt_tab-middle-on.gif')";
			getStyleObject('top_level_close_span').background = "url('images/mt_tab-middle-off-lefton.gif')";
			getStyleObject('cookie_delete').background = "url('images/mt_tab-middle-off-lefton.gif')";
			// getStyleObject('cookie_save').background = "url('images/mt_tab-middle-off-lefton.gif')";
			break;
	};

    launch_selected_header(showme, webApp);
	return true;
}
function resetTopBackgrounds() {
	getStyleObject("webmail_span").background = "url('images/mt_tab-left-off.gif')";
	getStyleObject("admin_span").background = "url('images/mt_tab-middle-off.gif')";
	getStyleObject("stats_span").background = "url('images/mt_tab-middle-off.gif')";
	getStyleObject("help_span").background = "url('images/mt_tab-middle-off.gif')";
	getStyleObject("cookie_delete").background = "url('images/mt_tab-middle-off.gif')";
	getStyleObject("cookie_save").background = "url('images/mt_tab-middle-off.gif')";
	getStyleObject("top_level_close_span").background = "url('images/mt_tab-right-off.gif')";
	hideThis("webmail");
	hideThis("admin");
	hideThis("stats");
	hideThis("help");
	return true;
}

function auth_valid() {
	if ( document.auth.password.value == ""         
      || document.auth.password.value == "password" 
      || document.auth.email.value    == "" 
      || document.auth.email.value    == "email address"
     ) 
     {
        parent.document.getElementById("mt_body").src = "mt-login.html";
        alert("You must be signed in to use webmail! Please enter an email address and password!");
        return false;
     };
     return true;
}

function launch_selected_header(show_me, webApp ) {

	switch ( show_me ) {
	    case "webmail":
            // if it was passed to us, use it
            if ( webApp ) {
	            display_subhead_menu_item( webApp );
                break;
            };

            // otherwise, check for a browser cookie
            var webmailCookie = read_webmail_from_cookie();
            if ( webmailCookie ) {
	            display_subhead_menu_item( webmailCookie );
                break;
            }

            // use mail administrators settings
	        if ( default_webmail != "" ) {
	            display_subhead_menu_item(default_webmail);
                parent.document.getElementById("mt_body").src = "mt-webmail.html";
                break;
	        }

            // since everything else failed...
	        display_subhead_menu_item("windex");
            // display the webmail page
            parent.document.getElementById("mt_body").src = "mt-webmail.html";
	        break;

	    case "admin":
	        if ( default_admin != "" ) {
	            display_subhead_menu_item(default_admin);
	        }
	        break;
        case "stats":
			showThis(show_me);
	        if ( default_statistics != "" ) {
	            display_subhead_menu_item(default_statistics);
	        }
	        break;
        case "help":
			showThis(show_me);
            parent.document.getElementById("mt_body").src = "mt-help.html";
            break;
	}
    return true;
}
function showThis(show_me) {

    // show the object we were passed
	var styleObject = getStyleObject(show_me);
	styleObject.visibility = "visible";

    // enables display for hidden blocks
	styleObject.display = "block";
}
function hideThis(hide_me) {

    // hide the object we were passed
	var styleObject = getStyleObject(hide_me);
	styleObject.visibility = "hidden";

    // disable display for block elements
	styleObject.display = "none";
}

function changeObjectVisibility(objectId, newVisibility) {
    // first get a reference to the cross-browser style object 
    // and make sure the object exists
    var styleObject = getStyleObject(objectId);
    if(objectId) {
                styleObject.visibility = newVisibility;
				styleObject.display = newVisibility;
                return true;
    } else {
                // we couldn't find the object, so we can't change its visibility
                return false;
    }
}
function getStyleObject(objectId) {
        // function getStyleObject(string) -> returns style object
        //  given a string containing the id of an object
        //  the function returns the stylesheet of that object
        //  or false if it can't find a stylesheet.  Handles
        //  cross-browser compatibility issues.
        //
        // checkW3C DOM, then MSIE 4, then NN 4.
        //
	if(document.getElementById && document.getElementById(objectId)) {
		return document.getElementById(objectId).style;
	}
	else if (document.all && document.all(objectId)) {  
		return document.all(objectId).style;
	} 
	else if (document.layers && document.layers[objectId]) { 
		return document.layers[objectId];
	} else {
		return false;
	}
}

function update_hidden_forms(dest) {

	// document.auth is the form the user interacts with. We copy their login
	// info to the hidden forms for each of the applications we provide

	document.roundcube._user.value = document.auth.email.value;
	document.roundcube._pass.value = document.auth.password.value;

	document.squirrel.login_username.value = document.auth.email.value;
	document.squirrel.secretkey.value = document.auth.password.value;

	document.sqwebmail.username.value = document.auth.email.value;
	document.sqwebmail.password.value = document.auth.password.value;

	document.vwebmail.username.value = document.auth.email.value;
	document.vwebmail.password.value = document.auth.password.value;

	document.imp.imapuser.value = document.auth.email.value;
	document.imp.pass.value = document.auth.password.value;

    // qmailadmin needs the account and domain separated
	var email_parts  = document.auth.email.value.split("@");
	document.qmailadmin.username.value = email_parts[0];
	document.qmailadmin.domain.value   = email_parts[1];
	document.qmailadmin.password.value = document.auth.password.value;
	
    // and ezmlm.cgi requires only the domain
	document.ezmlm.domain.value = email_parts[1];
	document.ezmlm.password.value = document.auth.password.value;
}

function create_cookie(name,value,days) {
    var expires = "";
	if (days) {
		var date = new Date();
		date.setTime(date.getTime()+(days*24*60*60*1000));
		expires = "; expires="+date.toGMTString();
	}
	document.cookie = name+"="+value+expires+"; path=/";
}
function read_cookie(name) {
	var nameEQ = name + "=";
	var ca = document.cookie.split(';');
	for(var i=0;i < ca.length;i++) {
		var c = ca[i];
		while (c.charAt(0)==' ') c = c.substring(1,c.length);
		if (c.indexOf(nameEQ) == 0) return c.substring(nameEQ.length,c.length);
	}
	return false;
}
function erase_cookie(name) {
	create_cookie(name,"",-1);
}

function webmail_choose (webmailChoice) {

    // save the choice in a cookie
    create_cookie('webmail', webmailChoice, 365);

    alert(" Your choice of webmail applications ("+webmailChoice+") will be remembered. Now when you click the 'webmail' link, you will automatically be taken to your chosen webmail application. You can change this by returning to the webmail->home link.");
}
function save_auth_settings(parentNeeded) {

    if ( document.auth.password.value != "" && document.auth.email.value != "" ) {
        
        // set the authentication cookies in the browser
        create_cookie('email', document.auth.email.value, 5);
    	create_cookie('sekret', document.auth.password.value, 5);

        read_auth_settings_from_cookies(parentNeeded);
        return true;
        
	} else {
	    alert("Sorry, but you must provide an email address and password!");
	    return false;
	}
}
function erase_auth_settings () {
    // erase the cookie
	erase_cookie('email', '', -1);
	erase_cookie('sekret', '', -1);

    // clear the form fields
    document.auth.email.value    = "";
    document.auth.password.value = "";

    read_auth_settings_from_cookies();
}
function read_webmail_from_cookie () {

    // read both authentication cookies from the browser
    var webmailCookie = read_cookie('webmail');
    if ( webmailCookie ) {
        return webmailCookie;
    } else {
        return false;
    }
}

function read_auth_settings_from_cookies (parentNeeded) {

    if ( parentNeeded ) {
        // parent.document.
    }

    // read both authentication cookies from the browser
    var email_from_cookie = read_cookie('email');
    var pass_from_cookie  = read_cookie('sekret');

	// if both cookies are set ...
	if ( pass_from_cookie != ""         && email_from_cookie != ""         
      && pass_from_cookie != "password" && email_from_cookie != "email address" 
    ) {

		// 1. an empty value is their "default state"
		// 2. but we put in help text to make it obvious what the fields are

        // the form has to be active in order to make changes to it
	    showThis('login_form_div');

        // update our form with the browser cookie values
        document.auth.email.value    = email_from_cookie;
	    document.auth.password.value = pass_from_cookie;

	    // disable the email & password fields until the user clicks "sign out"
	    document.auth.email.disabled = true;
	    document.auth.password.disabled = true;

	    // populate data into the hidden webmail forms
	    update_hidden_forms();

	    // hide the login span
	    hideThis('login_form_div');

	    // show/hide the login/logout links
	    // hideThis('cookie_save');
	    showThis('cookie_delete');
	    // showThis('quota_div');
	    
	    document.getElementById('signed_in').innerHTML=email_from_cookie;
        parent.document.getElementById("mt_body").src = "mt-webmail.html";

		return true;
	};

	// we are not logged in
	// enable the fields for user input
    try {
        // ie 6 chokes on this
		document.auth.password.type = "text";
	    document.auth.email.type = "text";
	} catch (error) {
        // alert(browser_error(error));
    }
    document.auth.email.disabled = false;
    document.auth.password.disabled = false;
        
    // reset the width of the email field
    document.auth.email.size = 16;

	// display the field descriptions
    document.auth.password.value = "password";
    document.auth.email.value = "email address"; 
        
	showThis('login_form_div');
	hideThis('cookie_delete');

	document.getElementById('signed_in').innerHTML="";
    parent.document.getElementById("mt_body").src = "mt-login.html";

	return true;
}

function browser_error(error) {
    alert("Your browser has an error ("+error+") in its Javascript implementation. This will cause certain features of this web site to not work correctly. We suggest using a better browser, such as darned near anything: FireFox, Mozilla, Netscape, Khtml, Safari, Opera, and even IE 7.");
}
function display_subhead_menu_item (activateme) {
    
    // we can't do a submit on a property that is not displayed
    // so we show the invisible form 
	showThis(activateme+'_div');

    var styleObject = "";
    
    // Do not edit the bottom_divs array! If you want certain elements removed
    // from the list, comment them out in the HTML with <!--  --> tags. You do
    // not want your JavaScript blowing up because an element in a loop is
    // missing. 

	var bottom_divs = new Array(
	    "squirrel",   "sqwebmail",   "vwebmail",
	    "imp",        "roundcube",   "qmailadmin", 
	    "ezmlm",      "rrdutil",     "munin",          "webmail_help",
	    "isoqlog",    "qss",         "ssl_help",       "vqadmin",
	    "pop3_help",  "imap_help",   "filtering_help", "vpopmail_help",
	    "antivirus_help", "windex",  "userguide"
    );

	// reset the colors for all the submenu items
	for (x in bottom_divs) {
		styleObject = getStyleObject(bottom_divs[x]+'_span');
//		styleObject.background = primary_background_color;
//		styleObject.background = primary_background_image;
		styleObject.color = primary_text_color;
	}
	
	// change the background color of our selected span
	styleObject = getStyleObject(activateme+'_span');
//	styleObject.background = active_background_color;
	styleObject.color = active_text_color;

    // hide the invisible form again
	hideThis(activateme+'_div');

    // alert ("displayed subhead "+activateme);
	launch_selected_web_app(activateme);
    return true;
}

function launch_selected_web_app(activateme) {
    
	// This is The Right Place[TM] to update the URL to your web application(s)
	// if the defaults shown below do not work for you, simply alter them.
	//
	// You do not need to worry about the URLs shown in the HTML, they get
	// overridden by the values set here.
	
    // alert ("launching web app "+activateme);

	switch ( activateme ) {
	    case "squirrel":
            if ( ! auth_valid() ) {
                return false;
            };
	        document.squirrel.action = mailhost+'/squirrelmail/src/redirect.php';
            document.squirrel.submit();
            break;
        case "sqwebmail":
            if ( ! auth_valid() ) {
                auth_valid();
            };
            document.sqwebmail.action = mailhost+'/cgi-bin/sqwebmail';
            document.sqwebmail.submit();
            break;
        case "vwebmail":
            if ( ! auth_valid() ) {
                return false;
            };
            document.vwebmail.action = mailhost+'/v-webmail/login.php?vwebmailsession=';
            document.vwebmail.submit();
            break;
        case "imp":
            if ( ! auth_valid() ) {
                return false;
            };
            document.imp.action = mailhost+'/horde/imp/index.php';
            document.imp.submit();
            break;
        case "roundcube":
            if ( ! auth_valid() ) {
                return false;
            };
            document.roundcube.action = mailhost+'/roundcube/index.php';
            document.roundcube.submit();
            break;
        case "qmailadmin":
            if ( ! auth_valid() ) {
                return false;
            };
            document.qmailadmin.action = mailhost+'/cgi-bin/qmailadmin';
            document.qmailadmin.submit();
            break;
        case "vqadmin":
            if ( ! auth_valid() ) {
                return false;
            };
            document.vqadmin.action = mailhost+'/cgi-bin/vqadmin/vqadmin.cgi';
            document.vqadmin.submit();
            break;
        case "rrdutil":
            document.rrdutil.action = mailhost+'/cgi-bin/rrdutil.cgi';
            document.rrdutil.submit();
            break;
        case "munin":
            document.munin.action = mailhost+'/munin/';
            document.munin.submit();
            break;
        case "ezmlm":
            document.ezmlm.action = mailhost+'/ezmlm.cgi';
            document.ezmlm.submit();
            break;
        case "isoqlog":
            document.isoqlog.action = mailhost+'/isoqlog/';
            document.isoqlog.submit();
            break;
        case "qss":
            document.qss.action = mailhost+'/qss/';
            document.qss.submit();
            break;
        case "userguide":
            document.userguide.action = mailhost+'/qmailadmin/images/help/email_user/';
            document.userguide.submit();
            break;
        case "webmail_help":
            document.webmail_help.action = mailhost+'/support/webmail.html';
            document.webmail_help.submit();
            break;
        case "imap_help":
            document.imap_help.action = mailhost+'/support/imap.html';
            document.imap_help.submit();
            break;
        case "pop3_help":
            document.pop3_help.action = mailhost+'/support/pop3.html';
            document.pop3_help.submit();
            break;
        case "filtering_help":
            document.filtering_help.action = mailhost+'/support/filtering.html';
            document.filtering_help.submit();
            break;
        case "antivirus_help":
            document.antivirus_help.action = mailhost+'/support/antivirus.html';
            document.antivirus_help.submit();
            break;
        case "ssl_help":
            document.ssl_help.action = mailhost+'/support/ssl.html';
            document.ssl_help.submit();
            break;
        case "vpopmail_help":
            document.vpopmail_help.action = mailhost+'/vpopmail/';
            document.vpopmail_help.submit();
            break;
	}
    return true;
}
