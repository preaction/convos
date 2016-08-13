(function() {
  Convos.mixin.message = {
    props:   ["dialog", "msg", "user"],
    methods: {
      classNames: function() {
        var msg = this.msg;
        var c = {highlight: this.msg.highlight ? true : false};

        if (msg.type != "action" && msg.message && msg.from == msg.prev.from) {
          c["same-user"] = true;
        }
        else {
          c["changed-user"] = true;
        }

        return c;
      },
      loadOffScreen: function(html, id) {
        if (html.match(/^<a\s/)) return;
        var self   = this;
        var $html  = $(html);
        var $paste = $html.filter('.text-paste, .text-gist-github');
        var $a     = $('#' + id);

        $html.filter("img").add($html.find("img")).addClass("embed materialboxed");
        $a.parent().append($html).find(".materialboxed").materialbox();

        $html.find("img, iframe").each(function() {
          $(this).css("height", "1px").load(function() {
            if (self.$parent.atBottom) self.$parent.scrollToBottom(true);
            $(this).css("height", "auto");
          });
        });
      },
      message: function() {
        var self = this;
        return this.msg.message.xmlEscape().autoLink({
          target: "_blank",
          after:  function(url, id) {
            $.get("/api/embed?url=" + encodeURIComponent(url), function(html, textStatus, xhr) {
              self.$dispatch("loadOffScreen", html, id);
            });
            return null;
          }
        });
      }
    }
  };
})();