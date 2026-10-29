var path = window.location.pathname;
var page = path.split("/").pop();
if (page != "adr.htm" && page != "index.htm") {
  /* Automatically apply and submit any changes to the following input elements
  select drop down menus, radio buttons, and file prompt buttons */
  var inputelements = document.querySelectorAll('select, input[type=radio]'), i;
  for (i = 0; i < inputelements.length; ++i) {
    inputelements[i].addEventListener('change',function() {
    this.form.submit();
    });
  }
};
/* Allow styling of input type="file" via css, also shows the number of files if multiple were selected*/
var inputs = document.querySelectorAll( '.inputfile' );
Array.prototype.forEach.call( inputs, function( input ) {
  var label = input.nextElementSibling,
  labelVal = label.innerHTML;
  input.addEventListener( 'change', function( e ) {
    var fileName = '';
    if ( this.files && this.files.length > 1 ) {
    fileName = ( this.getAttribute( 'data-multiple-caption' ) || '' ).replace( '{count}', this.files.length );
    } else {
    fileName = e.target.value.split( '\\' ).pop();
    }
    if( fileName ) {
    label.querySelector( 'span' ).innerHTML = fileName;
    } else {
    label.innerHTML = labelVal;
    }
  });
  /* On Firefox when the input is focused there is a bug that the highlight color is not used */
  input.addEventListener( 'focus', function(){ input.classList.add( 'has-focus' ); });
  input.addEventListener( 'blur', function(){ input.classList.remove( 'has-focus' ); });
});

/* Prevent Enter from submitting the delete identity photo element */
if (page = "line_login.htm") {
  var inputtypetext = document.querySelectorAll("input[type=text]");
  for (i = 0; i < inputtypetext.length; ++i) {
    inputtypetext[i].addEventListener("keydown", function(event) {
      if (event.key == "Enter") {
        document.getElementById('apply').click();
        event.preventDefault();
      }
    });
  }
};
