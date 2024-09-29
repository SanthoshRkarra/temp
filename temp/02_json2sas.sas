%macro json2sas(
    in_lib=,          /* Required: Path to the input SAS library containing the original dataset */
    json_lib=,        /* Required: Path to the directory where JSON files are located */
    out_lib=,         /* Required: Path to the output SAS library for reconstructed datasets */
    dataset=,         /* Required: Name of the dataset to reconstruct from JSON */
    out_json=,        /* Optional: Name of the input JSON file. Defaults to <dataset>.json */
    compare=YES,      /* Optional: Whether to perform PROC COMPARE. Options: YES or NO. Defaults to YES */
    debug=NO          /* Optional: Enable detailed debugging. Options: YES or NO. Defaults to NO */
);

    /* Validate Required Parameters */
    %if %length(&in_lib) = 0 or
        %length(&json_lib) = 0 or
        %length(&out_lib) = 0 or
        %length(&dataset) = 0 %then %do;
        %put ERROR: Missing required parameters. Please provide in_lib, json_lib, out_lib, and dataset.;
        %return;
    %end;

    /* Set Default for out_json if Not Provided */
    %if %length(&out_json) = 0 %then %do;
        %let out_json=&dataset..json;
    %end;

    /* Enable or Disable Macro Debugging */
    %if %upcase(&debug) = YES %then %do;
        options mprint mlogic symbolgen;
        %put NOTE: Macro debugging is ENABLED.;
    %end;
    %else %do;
        options nomprint nomlogic nosymbolgen;
        %put NOTE: Macro debugging is DISABLED.;
    %end;

    /* Assign Librefs */
    libname in "&in_lib";
    libname outlib "&out_lib";
    %let work_path = %sysfunc(pathname(work));

    /* Define the JSON Input File Path */
    filename injson "&json_lib.\&out_json";

    /* Step 1: Read the JSON File and Extract Metadata and Dataset Label */
    data meta_lines data_lines;
        infile injson lrecl=32767 truncover;
        length line $32767 value $256;
        retain in_metadata 0 in_data 0;
        input;
        line = strip(_infile_);

        /* Extract dataset label */
        if index(line, '"dataset_label":') then do;
            value = substr(line, index(line, ':') + 1);
            value = compress(value, '",');
            value = strip(value);
            call symputx('memlabel', value);
            %if %upcase(&debug) = YES %then %do;
                put 'DEBUG: Dataset Label=' value;
            %end;
        end;

        /* Detect the start and end of metadata section */
        else if index(line, '"metadata": [') then in_metadata = 1;
        else if index(line, ']') and in_metadata then in_metadata = 0;
        else if index(line, '"data": [') then in_data = 1;
        else if index(line, ']') and in_data then in_data = 0;

        /* Capture metadata lines */
        if in_metadata then output meta_lines;
        /* Capture data lines */
        else if in_data then output data_lines;
    run;

    /* Step 2: Read the Extracted Metadata into work.meta */
    data work.meta;
        set meta_lines;
        length meta_name $32 type 8 length 8 format $32 informat $32 label $256 varnum 8;
        retain in_object 0 meta_name type length format informat label varnum;
        line = strip(line);

        /* Check for the start of a new metadata object */
        if index(line, '{') then do;
            in_object = 1;
            /* Initialize variables */
            call missing(meta_name, type, length, format, informat, label, varnum);
            %if %upcase(&debug) = YES %then %do;
                put 'DEBUG: Starting a new metadata object.';
            %end;
        end;

        /* Process metadata key-value pairs */
        if in_object and index(line, ':') then do;
            key = strip(scan(line, 1, ':'));
            value = substr(line, index(line, ':') + 1);

            /* Remove unwanted characters using TRANWRD */
            key = tranwrd(tranwrd(key, '"', ''), ',}', '');
            value = tranwrd(tranwrd(value, '"', ''), ',', '');
            value = strip(value); /* Remove leading and trailing spaces */

            select (strip(upcase(key)));
                when ('NAME') meta_name = strip(value);
                when ('TYPE') type = input(value, best.);
                when ('LENGTH') length = input(value, best.);
                when ('FORMAT') format = strip(value);
                when ('INFORMAT') informat = strip(value);
                when ('LABEL') label = strip(value);
                when ('VARNUM') varnum = input(value, best.);
                otherwise;
            end;

            %if %upcase(&debug) = YES %then %do;
                put 'DEBUG: Parsed ' key ' = ' value;
            %end;
        end;

        /* Check for the end of the metadata object */
        if index(line, '}') then do;
            if in_object then do;
                in_object = 0;
                %if %upcase(&debug) = YES %then %do;
                    put 'DEBUG: At closing brace. meta_name=' meta_name;
                %end;
                if not missing(meta_name) then do;
                    meta_name = strip(meta_name); /* Remove trailing spaces */
                    output;
                    %if %upcase(&debug) = YES %then %do;
                        put 'DEBUG: Outputting metadata for variable=' meta_name;
                    %end;
                end;
            end;
        end;

    run;

    /* Check if Metadata Dataset has Observations */
    %let dsid = %sysfunc(open(work.meta));
    %let nobs = %sysfunc(attrn(&dsid, nlobs));
    %let rc = %sysfunc(close(&dsid));

    %if &nobs = 0 %then %do;
        %put ERROR: The metadata dataset is empty. Please check the JSON file and parsing code.;
        %return;
    %end;
    %else %do;
        %put NOTE: Metadata dataset contains &nobs observations.;
    %end;

    /* Sort the Metadata by varnum */
    proc sort data=work.meta; by varnum; run;

    /* Step 5: Build the Data Step to Read the Data Section */
%macro generate_datastep;
    filename datastep "&work_path./read_data.sas";

    data _null_;
        file datastep lrecl=32767;
        set work.meta end=last nobs=nobs;

        /* Define variable lengths */
        length meta_name $32 code_line $200 varlist $2000 label_esc $256 up_meta_name $32;

        /* Retain varlist across iterations */
        retain varlist '';

        /* At the first iteration, write the data step header */
        if _n_ = 1 then do;
            %if %length(&memlabel) > 0 %then %do;
                put 'data outlib.&dataset (label="' "&memlabel" '");';
            %end;
            %else %do;
                put 'data outlib.&dataset;';
            %end;
        end;

        /* Define LENGTH statements */
        meta_name = strip(meta_name); /* Ensure meta_name has no trailing spaces */

        if type = 2 then do;
            put 'length ' meta_name ' $' length ';';
        end;
        else do;
            put 'length ' meta_name ' 8;';
        end;

        /* Apply FORMAT if it exists */
        if not missing(format) then do;
            /* Ensure format ends with a period */
            if substr(format, length(format), 1) ne '.' then format = cats(format, '.');
            /* For character variables, ensure format starts with $ */
            if type = 2 and substr(format, 1, 1) ne '$' and format ne '' then format = cats('$', format);
            put 'format ' meta_name ' ' format ';';
        end;

        /* Apply INFORMAT if it exists */
        if not missing(informat) then do;
            /* Ensure informat ends with a period */
            if substr(informat, length(informat), 1) ne '.' then informat = cats(informat, '.');
            /* For character variables, ensure informat starts with $ */
            if type = 2 and substr(informat, 1, 1) ne '$' and informat ne '' then informat = cats('$', informat);
            put 'informat ' meta_name ' ' informat ';';
        end;

        /* Apply LABEL if it exists */
        if not missing(label) then do;
            /* Escape any double quotes in the label */
            label_esc = tranwrd(label, '"', '""');
            put 'label ' meta_name ' = "' label_esc '";';
        end;

        /* Build the varlist */
        varlist = catx(' ', varlist, meta_name);

        /* Output varlist for debugging */
        %if %upcase(&debug) = YES %then %do;
            put '/* DEBUG: varlist=' varlist ' */';
        %end;

        /* At the end, write the rest of the data step */
        if last then do;
            put 'set data_lines;';
            put 'length key $32 value $256;';
            put 'line = strip(line);';
            put 'retain ' varlist ';';
            put 'if index(line, ''{'') then do;';
            put '   call missing(of ' varlist ');';
            put 'end;';
            put 'else if index(line, ''}'') then do;';
            put '   output;';
            put 'end;';
            put 'else if index(line, '':'') then do;';
            /* Corrected parsing of key and value */
            put '   key = strip(scan(line, 1, '':''));';
            put '   key = compress(key, ''" ,{}'');';
            put '   key = upcase(strip(key));';
            put '   value = substr(line, index(line, '':'' ) + 1);';
            put '   value = compress(value, ''",'');';
            put '   value = strip(value);';

            %if %upcase(&debug) = YES %then %do;
                put '   put ''DEBUG: key='' key '' value='' value;';
            %end;

            /* Generate the select statement */
            put '   select (key);';
            /* Read the entire meta dataset to generate when clauses */
            do i = 1 to nobs;
                set work.meta point=i nobs=nobs;
                length meta_name $32; /* Ensure meta_name has sufficient length */
                meta_name = strip(meta_name); /* Remove any leading/trailing spaces */
                up_meta_name = upcase(meta_name);

                if type = 2 then do;
                    code_line = '       when ("' || up_meta_name || '") ' || meta_name || ' = value;';
                end;
                else do;
                    code_line = '       when ("' || up_meta_name || '") ' || meta_name || ' = input(value, best32.);';
                end;
                put code_line;
            end;
            put '       otherwise;';
            put '   end;';
            put 'end;';
            put 'keep ' varlist ';';
            put 'run;';
        end;
    run;

    filename datastep clear;
%mend generate_datastep;

    /* Generate and Execute the Data Step */
    %generate_datastep;
    %include "&work_path./read_data.sas";

    /* Verify the Reconstructed Dataset */
    proc print data=outlib.&dataset (obs=5) noobs; /* Display first 5 observations for brevity */
    run;

    /* Compare the Original and Reconstructed Datasets */
    %if %upcase(&compare) = YES %then %do;
        proc compare base=in.&dataset compare=outlib.&dataset listall method=exact;
        run;
    %end;
    %else %do;
        %put NOTE: Comparison step is skipped as per the compare parameter.;
    %end;

%mend json2sas;

/* Example Usage */
%json2sas(
    in_lib=C:\Projects\macrolib\SAS2JSON\in,
    json_lib=C:\Projects\macrolib\SAS2JSON\out,
    out_lib=C:\Projects\macrolib\SAS2JSON\out2,
    dataset=cars,
    compare=YES,
    debug=YES
);


/*proc contents data=outlib.cars;*/
/*run;*/
/**/
/*proc print data=outlib.cars(obs=5);*/
/*run;*/
